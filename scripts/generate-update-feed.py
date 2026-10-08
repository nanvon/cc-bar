#!/usr/bin/env python3
"""为最终发布包生成并签名 Sparkle appcast，不接触用户本机安装。"""

import argparse
import base64
import binascii
from datetime import datetime, timezone
from email.utils import format_datetime
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode_key(value, lengths, name):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError(f"{name} 格式无效，请使用 Sparkle generate_keys 的输出") from None
    require(len(decoded) in lengths, f"{name} 长度无效")
    return decoded


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--dist", required=True, type=Path)
    parser.add_argument("--sign-update", required=True, type=Path)
    args = parser.parse_args()
    require(re.fullmatch(r"v\d+\.\d+\.\d+", args.tag), "发布 tag 必须是 vX.Y.Z")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository), "仓库名称无效")
    require(args.sign_update.is_file(), "找不到 Sparkle sign_update")

    public_key = os.environ.get("SPARKLE_PUBLIC_ED_KEY", "").strip()
    private_key = os.environ.get("SPARKLE_PRIVATE_ED_KEY", "").strip()
    require(public_key and private_key, "发布前必须配置 Sparkle 公钥 variable 和私钥 secret")
    decode_key(public_key, (32,), "SPARKLE_PUBLIC_ED_KEY")
    # generate_keys 新格式是 32 字节 seed；旧格式是 64 字节私钥加 32 字节公钥。
    decode_key(private_key, (32, 96), "SPARKLE_PRIVATE_ED_KEY")
    child_env = os.environ.copy()
    child_env.pop("SPARKLE_PRIVATE_ED_KEY", None)

    with (args.app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version = args.tag[1:]
    require(info.get("CFBundleShortVersionString") == version, "tag 与 App 显示版本不一致")
    require(info.get("CFBundleVersion") == version, "App 构建版本必须与发布版本一致并逐版递增")
    require(info.get("SUPublicEDKey") == public_key, "App 内置公钥与 CI 公钥不一致")
    require(info.get("SURequireSignedFeed") is True, "发布 App 必须启用签名 feed 验证")
    require(info.get("SUVerifyUpdateBeforeExtraction") is True, "发布 App 必须在解压前验签")

    release_base = f"https://github.com/{args.repository}/releases/download/{args.tag}"
    history_url = f"https://github.com/{args.repository}/releases/latest/download/release-notes.md"
    feed_url = f"https://github.com/{args.repository}/releases/latest/download/appcast.xml"
    require(info.get("SUFeedURL") == feed_url, "App 更新源与发布仓库不一致")
    minimum_os = str(info.get("LSMinimumSystemVersion", ""))
    require(re.fullmatch(r"\d+(?:\.\d+){1,2}", minimum_os), "App 最低 macOS 版本缺失")
    if minimum_os.count(".") == 1:
        minimum_os += ".0"

    executable_name = info.get("CFBundleExecutable", "")
    require(isinstance(executable_name, str) and executable_name
            and executable_name not in (".", "..") and Path(executable_name).name == executable_name,
            "App 主执行文件名称无效")
    executable = args.app / "Contents/MacOS" / executable_name
    architectures_result = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(executable)],
        check=True, text=True, capture_output=True, env=child_env,
    )
    architectures = set(architectures_result.stdout.split())
    require(architectures and architectures <= {"arm64", "x86_64"},
            "App 主执行文件包含未知或缺失的架构，停止发布")

    root = Path(__file__).resolve().parent.parent
    note_files = []
    for note in (root / "release-notes").glob("v*.md"):
        match = re.fullmatch(r"v(\d+\.\d+\.\d+)\.md", note.name)
        if match and version_tuple(match[1]) <= version_tuple(version):
            content = re.sub(r"<!--.*?-->", "", note.read_text(encoding="utf-8"), flags=re.DOTALL).strip()
            if content:
                note_files.append((version_tuple(match[1]), match[1], content))
    note_files.sort(reverse=True)
    require(note_files and note_files[0][1] == version, "当前版本更新说明缺失或只有注释")
    args.dist.mkdir(parents=True, exist_ok=True)
    archive = args.dist / "CCBar.app.zip"
    require(archive.is_file() and archive.stat().st_size > 0, "最终 ZIP 更新包缺失")
    release_notes = args.dist / "release-notes.md"
    release_notes.write_text("\n\n".join(f"## {item[1]}\n\n{item[2]}" for item in note_files) + "\n", encoding="utf-8")

    # 私钥只经 stdin 交给 Sparkle，子进程环境不再携带它，不打印签名工具的原始输出。
    def sign(path):
        completed = subprocess.run(
            [str(args.sign_update), "--ed-key-file", "-", "--disable-signing-warning", "-p", str(path)],
            input=private_key + "\n", text=True, capture_output=True, env=child_env,
        )
        require(completed.returncode == 0, f"Sparkle 签名失败：{path.name}")
        signature = completed.stdout.strip()
        if path.suffix != ".xml":
            decode_key(signature, (64,), f"{path.name} 签名")
        return signature

    archive_signature = sign(archive)
    subprocess.run(
        ["xcrun", "swift", str(root / "scripts/verify-update-signature.swift"), public_key, archive_signature, str(archive)],
        check=True, env=child_env,
    )
    notes_signature = sign(release_notes)

    feed = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(feed, "channel")
    ET.SubElement(channel, "title").text = "CCBar Updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{args.repository}/releases"
    ET.SubElement(channel, "description").text = "CCBar application updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"CCBar {version}"
    ET.SubElement(item, "link").text = f"https://github.com/{args.repository}/releases/tag/{args.tag}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = minimum_os
    if architectures == {"arm64"}:
        ET.SubElement(item, f"{{{SPARKLE_NS}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink", {
        f"{{{SPARKLE_NS}}}edSignature": notes_signature,
        f"{{{SPARKLE_NS}}}length": str(release_notes.stat().st_size),
    }).text = f"{release_base}/release-notes.md"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = history_url
    ET.SubElement(item, "enclosure", {
        "url": f"{release_base}/CCBar.app.zip",
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": archive_signature,
    })
    ET.indent(feed, space="  ")
    appcast = args.dist / "appcast.xml"
    ET.ElementTree(feed).write(appcast, encoding="utf-8", xml_declaration=True)
    unsigned_feed_length = appcast.stat().st_size
    sign(appcast)  # 官方工具按 Sparkle 格式嵌入 feed 签名，之后不得再修改 XML。
    signed_feed = appcast.read_bytes()
    signing_block_start = signed_feed.rfind(b"<!-- sparkle-signatures:\n")
    require(signing_block_start == unsigned_feed_length, "Sparkle 未在 appcast 尾部写入签名块")
    signing_block = re.fullmatch(
        rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: (\d+)\n-->\n",
        signed_feed[signing_block_start:],
    )
    require(signing_block is not None and int(signing_block[2]) == unsigned_feed_length,
            "appcast 签名长度不匹配")
    decode_key(signing_block[1].decode("ascii"), (64,), "appcast 签名")
    (args.dist / "version.json").write_text(json.dumps({
        "tag": args.tag,
        "version": version,
        "page": f"https://github.com/{args.repository}/releases/tag/{args.tag}",
    }, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"已生成并签名 {args.tag} 的更新源、历史日志和旧版版本清单")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f"生成更新源失败：{error}", file=sys.stderr)
        sys.exit(1)
