#!/usr/bin/env python3
import argparse
import json
import plistlib
import sys
import urllib.error
import urllib.request
import zipfile


def parse_exists_payload(payload):
    if isinstance(payload, bool):
        return {"state": "success", "exists": payload, "detail": "boolean response"}

    if isinstance(payload, dict):
        for key in ("exists", "found", "inLibrary", "in_library", "isInLibrary", "matched", "present"):
            value = payload.get(key)
            if isinstance(value, bool):
                return {"state": "success", "exists": value, "detail": f"parsed {key}"}

        data_value = payload.get("data")
        if isinstance(data_value, dict):
            for key in ("exists", "found", "inLibrary", "in_library", "isInLibrary", "matched", "present"):
                value = data_value.get(key)
                if isinstance(value, bool):
                    result = {"state": "success", "exists": value, "detail": f"parsed data.{key}"}
                    if isinstance(data_value.get("match_type"), str):
                        result["match_type"] = data_value["match_type"]
                    matched_track = data_value.get("matched_track")
                    if isinstance(matched_track, dict):
                        result["matched_title"] = matched_track.get("title")
                        result["matched_artist"] = matched_track.get("artist")
                    return result

        track_value = payload.get("track", payload.get("result", payload.get("match")))
        if isinstance(track_value, dict):
            return {"state": "success", "exists": True, "detail": "track object present"}

        if isinstance(track_value, list):
            return {"state": "success", "exists": len(track_value) > 0, "detail": "track array present"}

        return {"state": "unrecognized-response", "exists": False, "detail": payload.get("message") or payload.get("detail") or "unrecognized JSON response"}

    if isinstance(payload, str):
        normalized = payload.strip().lower()
        if normalized in {"true", "yes", "found", "exists"}:
            return {"state": "success", "exists": True, "detail": "string response"}
        if normalized in {"false", "no", "missing", "not_found"}:
            return {"state": "success", "exists": False, "detail": "string response"}

    return {"state": "unrecognized-response", "exists": False, "detail": "could not parse exists response"}


def run_exists_api_regressions():
    checks = [
        (parse_exists_payload({"exists": True}), {"state": "success", "exists": True}, "dict exists=true should parse"),
        (parse_exists_payload({"exists": False}), {"state": "success", "exists": False}, "dict exists=false should parse"),
        (parse_exists_payload({"success": True, "data": {"exists": True, "match_type": "alternate_version", "matched_track": {"title": "Sve mi dobro ide (Remix)", "artist": "The Balkanizer"}}}), {"state": "success", "exists": True}, "nested data.exists should parse"),
        (parse_exists_payload({"track": {"title": "Sve mi dobro ide (Remix)"}}), {"state": "success", "exists": True}, "track object should imply exists"),
        (parse_exists_payload(True), {"state": "success", "exists": True}, "boolean true should parse"),
        (parse_exists_payload("false"), {"state": "success", "exists": False}, "string false should parse"),
    ]

    failures = []
    for actual, expected, message in checks:
        if actual["state"] != expected["state"] or actual["exists"] != expected["exists"]:
            failures.append(message)

    if failures:
        raise AssertionError("; ".join(failures))


def verify_ats_in_ipa(ipa_path: str):
    with zipfile.ZipFile(ipa_path) as zf:
        plist_name = next(name for name in zf.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist"))
        with zf.open(plist_name) as fp:
            info = plistlib.load(fp)

    ats = info.get("NSAppTransportSecurity", {})
    exceptions = ats.get("NSExceptionDomains", {})
    target = exceptions.get("62.146.177.62", {})
    if not ats.get("NSAllowsArbitraryLoads") or not target.get("NSExceptionAllowsInsecureHTTPLoads"):
        raise AssertionError("ATS exception for 62.146.177.62 missing from built IPA")


def probe_exists_api(api_url: str, songs):
    for title, artist in songs:
        payload = json.dumps({"title": title, "artist": artist}).encode("utf-8")
        request = urllib.request.Request(
            api_url,
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                text = body.decode("utf-8", errors="replace")
                parsed_body = json.loads(text) if text else None
                parsed_result = parse_exists_payload(parsed_body) if parsed_body is not None else {"state": "success", "exists": False, "detail": "empty response body"}
                print(json.dumps({
                    "title": title,
                    "artist": artist,
                    "status": response.status,
                    "result": parsed_result,
                    "raw": parsed_body if parsed_body is not None else text,
                }, ensure_ascii=False))
        except urllib.error.HTTPError as exc:
            print(json.dumps({
                "title": title,
                "artist": artist,
                "status": exc.code,
                "error": f"HTTP {exc.code}",
                "raw": exc.read().decode("utf-8", errors="replace"),
            }, ensure_ascii=False))
        except Exception as exc:
            print(json.dumps({
                "title": title,
                "artist": artist,
                "error": repr(exc),
            }, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa")
    parser.add_argument("--probe-api", action="store_true")
    parser.add_argument("--probe-exists-api", action="store_true")
    parser.add_argument("--api-url", default="https://radio-v2.subasically.me/api/tracks/exists")
    args = parser.parse_args()

    run_exists_api_regressions()
    print("exists_api_regressions=ok")

    if args.ipa:
        verify_ats_in_ipa(args.ipa)
        print(f"ats_verification=ok ipa={args.ipa}")

    if args.probe_api or args.probe_exists_api:
        probe_exists_api(args.api_url, [
            ("Sve mi dobro ide BLKNZD", "The Balkanizer"),
            ("3. Svetski Rat", "Trubatron Soundsystem"),
        ])


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
