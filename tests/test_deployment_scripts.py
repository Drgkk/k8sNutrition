"""Exercise deployment orchestration without connecting to Docker or Kubernetes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
event = {"tool": name, "args": args}
if name == "kubectl" and "apply" in args and "-f" in args:
    event["manifest"] = Path(args[args.index("-f") + 1]).read_text()
with open(os.environ["TEST_LOG"], "a") as stream:
    stream.write(json.dumps(event) + "\n")
if name == "id":
    print("1000" if "-u" in args else "uid=1000(test) gid=1000(test)")
if name == "docker" and "build" in args and os.environ.get("FAIL_BUILD"):
    sys.exit(42)
if name == "kubectl":
    if "cluster-info" in args and os.environ.get("STOPPED"):
        sys.exit(1)
    if "get" in args and "configmap/nutrition-config" in args and os.environ.get("MISSING"):
        sys.exit(1)
    if args[-2:] == ["-o", "name"] and os.environ.get("LEGACY"):
        print("deployment.apps/nutrition")
    if "can-i" in args:
        print("yes")
'''


class DeploymentScriptsTest(unittest.TestCase):
    def run_script(self, name, **flags):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary_dir = work / "bin"
            binary_dir.mkdir()
            stub = binary_dir / "stub"
            stub.write_text(STUB)
            stub.chmod(0o755)
            for tool in ["id", "docker", "minikube", "kubectl"]:
                (binary_dir / tool).symlink_to(stub)
            log = work / "commands.jsonl"
            env = {**os.environ, "PATH": f"{binary_dir}:{os.environ['PATH']}",
                   "TEST_LOG": str(log), "GITHUB_SHA": "a" * 40,
                   "GITHUB_RUN_ID": "101", "GITHUB_RUN_ATTEMPT": "1"}
            for flag in ["STOPPED", "MISSING", "LEGACY", "FAIL_BUILD"]:
                env.pop(flag, None)
            env.update(flags)
            result = subprocess.run(["bash", str(ROOT / "scripts" / name)],
                                    env=env, text=True, capture_output=True, timeout=20)
            events = [json.loads(line) for line in log.read_text().splitlines()]
            return result, events

    def test_bootstrap_sets_up_infrastructure_without_building_or_deploying_java(self):
        result, events = self.run_script("bootstrap.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(e["tool"] == "minikube" and "start" in e["args"] for e in events))
        files = {Path(e["args"][e["args"].index("-f") + 1]).name
                 for e in events if "manifest" in e}
        self.assertEqual(files, {"namespace.yaml", "config.yaml", "secret.yaml",
                                "postgres-pv.yaml", "postgres-pvc.yaml", "postgres-service.yaml",
                                "postgres-deployment.yaml", "java-service.yaml", "ingress.yaml",
                                "loadbalancer.yaml"})
        self.assertFalse(any(e["tool"] == "docker" and "build" in e["args"] for e in events))
        self.assertFalse(any("restart" in e["args"] for e in events))

    def test_deploy_only_applies_java_with_built_and_loaded_unique_tags(self):
        result, events = self.run_script("deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        applied = [e["manifest"] for e in events if "manifest" in e]
        self.assertEqual(len(applied), 1)
        self.assertEqual(applied[0].count("kind: Deployment"), 2)
        for version in ["v1", "v2"]:
            image = f"nutrition-api:{version}-{'a' * 40}-101-1"
            self.assertIn(f"image: {image}\n", applied[0])
            self.assertTrue(any(e["tool"] == "docker" and "build" in e["args"]
                                and image in e["args"] for e in events))
            self.assertTrue(any(e["tool"] == "minikube" and "load" in e["args"]
                                and image in e["args"] for e in events))
        self.assertNotIn("name: postgres\n", applied[0])
        self.assertFalse(any(e["tool"] == "minikube" and
                             ("start" in e["args"] or "addons" in e["args"]) for e in events))
        self.assertFalse(any("restart" in e["args"] for e in events))

    def test_stopped_cluster_or_missing_infrastructure_fails_before_builds(self):
        for flag in ["STOPPED", "MISSING"]:
            with self.subTest(flag=flag):
                result, events = self.run_script("deploy.sh", **{flag: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("bootstrap.sh", result.stderr)
                self.assertFalse(any(e["tool"] == "minikube" for e in events))
                self.assertFalse(any(e["tool"] == "docker" and "build" in e["args"] for e in events))
                self.assertFalse(any("manifest" in e for e in events))

    def test_failed_build_does_not_apply_anything(self):
        result, events = self.run_script("deploy.sh", FAIL_BUILD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("manifest" in e for e in events))

    def test_bootstrap_rejects_legacy_deployment_before_applying_resources(self):
        result, events = self.run_script("bootstrap.sh", LEGACY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("migration", result.stderr)
        self.assertFalse(any("manifest" in e for e in events))


if __name__ == "__main__":
    unittest.main()
