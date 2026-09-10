#!/usr/bin/env python3
"""Check Werify's migration gate without contacting a cluster (kubectl + yq v4)."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ghcr.io/prem-prakash/werify"
ENVIRONMENTS = {"staging": "staging", "production": "main"}


def yaml_documents(source):
    result = subprocess.run(
        ["yq", "eval-all", "-o=json", "[.]", "-"],
        input=source, text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


def render(path):
    result = subprocess.run(
        ["kubectl", "kustomize", str(path)],
        text=True, capture_output=True, check=True,
    )
    return yaml_documents(result.stdout)


class MigrationGateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = {
            environment: render(ROOT / "gitops" / environment / "werify")
            for environment in ENVIRONMENTS
        }

    def resource(self, documents, kind, name):
        matches = [
            resource for resource in documents
            if resource["kind"] == kind and resource["metadata"]["name"] == name
        ]
        self.assertEqual(len(matches), 1, f"expected one {kind}/{name}")
        return matches[0]

    def test_job_blocks_sync_and_retains_diagnostics(self):
        for environment, documents in self.rendered.items():
            with self.subTest(environment=environment):
                job = self.resource(documents, "Job", "werify-migrate")
                self.assertEqual(job["metadata"]["namespace"], f"werify-{environment}")
                annotations = job["metadata"]["annotations"]
                self.assertEqual(annotations["argocd.argoproj.io/hook"], "PreSync")
                self.assertEqual(
                    annotations["argocd.argoproj.io/hook-delete-policy"],
                    "BeforeHookCreation",
                )
                spec = job["spec"]
                for key, value in {
                    "parallelism": 1, "completions": 1,
                    "backoffLimit": 0, "activeDeadlineSeconds": 1800,
                }.items():
                    self.assertEqual(spec[key], value, key)
                self.assertNotIn("ttlSecondsAfterFinished", spec)
                pod = spec["template"]["spec"]
                self.assertEqual(pod["restartPolicy"], "Never")
                self.assertEqual(len(pod["containers"]), 1)
                self.assertFalse(pod.get("initContainers"))
                container = pod["containers"][0]
                self.assertEqual(container["command"], ["/app/bin/migrate"])
                self.assertFalse(container.get("args"))
                for key in ("startupProbe", "readinessProbe", "livenessProbe", "ports"):
                    self.assertNotIn(key, container)
                self.assertFalse(container.get("volumeMounts"))
                self.assertFalse(pod.get("volumes"))

    def test_job_uses_app_image_and_secrets_but_is_not_a_service_endpoint(self):
        for environment, documents in self.rendered.items():
            with self.subTest(environment=environment):
                job = self.resource(documents, "Job", "werify-migrate")
                deployment = self.resource(documents, "Deployment", "werify")
                job_pod = job["spec"]["template"]["spec"]
                app_pod = deployment["spec"]["template"]["spec"]
                job_container, app_container = (
                    job_pod["containers"][0], app_pod["containers"][0]
                )
                self.assertEqual(job_container["image"], app_container["image"])
                self.assertEqual(job_container["imagePullPolicy"], "Always")
                self.assertEqual(job_container["envFrom"], app_container["envFrom"])
                self.assertEqual(job_pod["imagePullSecrets"], app_pod["imagePullSecrets"])
                labels = job["spec"]["template"]["metadata"]["labels"]
                for name in ("werify", "cluster"):
                    service = self.resource(documents, "Service", name)
                    self.assertFalse(all(
                        labels.get(key) == value
                        for key, value in service["spec"]["selector"].items()
                    ), f"migration Job matches Service/{name}")

    def test_app_starts_http_without_running_migrations(self):
        for environment, documents in self.rendered.items():
            with self.subTest(environment=environment):
                deployment = self.resource(documents, "Deployment", "werify")
                container = deployment["spec"]["template"]["spec"]["containers"][0]
                self.assertEqual(container["command"], ["/app/bin/werify", "start"])
                self.assertFalse(container.get("args"))
                env = {entry["name"]: entry.get("value") for entry in container["env"]}
                self.assertEqual(env["PHX_SERVER"], "true")

    def test_image_updater_digest_transform_covers_both_workloads(self):
        updater = yaml_documents((
            ROOT / "gitops/argocd-image-updater/image-updater-cr.yaml"
        ).read_text())[0]["spec"]
        self.assertEqual(updater["writeBackConfig"]["method"], "argocd")
        for environment, tag in ENVIRONMENTS.items():
            reference = next(
                app for app in updater["applicationRefs"]
                if app["namePattern"] == f"werify-{environment}"
            )
            self.assertEqual(reference["images"][0]["imageName"], f"{IMAGE}:{tag}")
            settings = reference["images"][0].get(
                "commonUpdateSettings", updater["commonUpdateSettings"]
            )
            self.assertEqual(settings["updateStrategy"], "digest")
            # Mirror Argo's spec.source.kustomize.images override. A second
            # digest checks that a subsequent image update reaches both pods.
            for digest in ("sha256:" + "a" * 64, "sha256:" + "b" * 64):
                with self.subTest(environment=environment, digest=digest):
                    with tempfile.TemporaryDirectory(prefix="werify-migrations-") as temporary:
                        path = Path(temporary) / "werify"
                        shutil.copytree(ROOT / "gitops" / environment / "werify", path)
                        with (path / "kustomization.yaml").open("a") as config:
                            config.write(
                                f"\nimages:\n  - name: {IMAGE}\n"
                                f"    newTag: {tag}\n    digest: {digest}\n"
                            )
                        documents = render(path)
                    for kind, name in (("Job", "werify-migrate"), ("Deployment", "werify")):
                        resource = self.resource(documents, kind, name)
                        container = resource["spec"]["template"]["spec"]["containers"][0]
                        self.assertEqual(container["image"], f"{IMAGE}:{tag}@{digest}")

    def test_applications_use_full_automated_sync(self):
        for environment in ENVIRONMENTS:
            with self.subTest(environment=environment):
                application = yaml_documents((
                    ROOT / "gitops/applications" / f"werify-{environment}.yaml"
                ).read_text())[0]
                spec = application["spec"]
                self.assertEqual(spec["source"]["path"], f"gitops/{environment}/werify")
                policy = spec["syncPolicy"]
                self.assertTrue(policy["automated"]["prune"])
                self.assertTrue(policy["automated"]["selfHeal"])
                self.assertNotIn("ApplyOutOfSyncOnly=true", policy.get("syncOptions", []))


if __name__ == "__main__":
    unittest.main(verbosity=2)
