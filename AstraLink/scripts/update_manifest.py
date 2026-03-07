import argparse
import json
from datetime import UTC, datetime
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update AstraLink releases manifest.")
    parser.add_argument("--manifest", default="releases/manifest.json", help="Manifest file path")
    parser.add_argument("--platform", choices=["windows", "android", "web"], required=True)
    parser.add_argument("--version", required=True, help="Version in format 1.2.3+4")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--minimum-supported-version", default=None)
    parser.add_argument("--notes", default="")
    parser.add_argument("--mandatory", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    path = Path(args.manifest)
    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists():
        manifest = json.loads(path.read_text(encoding="utf-8"))
    else:
        manifest = {"channels": {}}

    channels = manifest.setdefault("channels", {})
    channel_data = channels.setdefault(args.channel, {})
    channel_data[args.platform] = {
        "latest_version": args.version,
        "minimum_supported_version": args.minimum_supported_version or args.version,
        "mandatory": bool(args.mandatory),
        "download_url": args.download_url,
        "notes": args.notes,
    }
    manifest["generated_at"] = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Updated {path} for {args.platform} {args.version} ({args.channel})")


if __name__ == "__main__":
    main()
