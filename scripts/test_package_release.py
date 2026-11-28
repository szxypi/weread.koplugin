"""Check that the release archive includes only versioned plugin files."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from zipfile import ZipFile


class PackageReleaseTest(unittest.TestCase):
    def test_local_files_are_excluded_from_the_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            (repo / "scripts").mkdir()
            script = repo / "scripts/package_release.sh"
            shutil.copyfile(Path(__file__).with_name(script.name), script)

            tracked = {
                "_meta.lua": '    version = "1.2.3",\n',
                "main.lua": "return {}\n",
                "LICENSE": "License\n",
                "NOTICE": "Notice\n",
                "README.md": "Readme\n",
                "fonts/.keep": "",
                "icons/.keep": "",
                "integrations/.keep": "",
                "weread/lib/plugin module.lua": "return {}\n",
            }
            for name, data in tracked.items():
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data, encoding="utf-8")
            (repo / ".gitignore").write_text("config.lua\n", encoding="utf-8")
            subprocess.run(["git", "add", "--", ".gitignore", *tracked], cwd=repo, check=True)
            (repo / "weread/lib/config.lua").write_text("-- local configuration", encoding="utf-8")
            (repo / "weread/lib/draft.lua").write_text("-- local draft", encoding="utf-8")

            candidate = repo / "candidate.zip"
            subprocess.run(["bash", str(script), str(candidate)], cwd=repo, capture_output=True, check=True)
            with ZipFile(candidate) as archive:
                files = {member.filename: archive.read(member) for member in archive.infolist() if not member.is_dir()}
            self.assertEqual(files, {f"weread.koplugin/{name}": data.encode("utf-8") for name, data in tracked.items()})


if __name__ == "__main__":
    unittest.main()
