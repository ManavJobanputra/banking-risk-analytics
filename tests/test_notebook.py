"""Reproducibility tests for the Python EDA notebook.

The notebook originally loaded its input from ``/content/Banking01.xlsx`` — a
Google Colab absolute path to a file that is not part of this repository, which
meant it could not run from a fresh clone at all. These tests pin the fix
generally: no absolute/Colab paths, and every data file the notebook names must
actually exist in the repository.
"""
from __future__ import annotations

import io
import json
import re
import sys
import tokenize
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import _data  # noqa: E402

# Quoted filenames with a data-ish extension, e.g. "Banking.csv"
DATA_FILE_RE = re.compile(r"""['"]([^'"]+\.(?:csv|xlsx|xls|json|parquet))['"]""")


def _strip_comments(src: str) -> str:
    """Drop comment tokens so these tests inspect code, not prose about it.

    Without this, an explanatory comment that *mentions* the old Colab path
    reads as though the code still used it.
    """
    try:
        parts = [
            tok.string
            for tok in tokenize.generate_tokens(io.StringIO(src).readline)
            if tok.type != tokenize.COMMENT
        ]
        return " ".join(parts)
    except (tokenize.TokenError, IndentationError, SyntaxError):
        return "\n".join(line.split("#", 1)[0] for line in src.splitlines())


def _code_sources() -> list[str]:
    nb = json.loads(_data.NOTEBOOK_PATH.read_text())
    return [
        _strip_comments("".join(cell["source"]))
        for cell in nb["cells"]
        if cell["cell_type"] == "code"
    ]


class TestNotebookReproducibility(unittest.TestCase):
    def test_notebook_exists_with_single_extension(self):
        self.assertTrue(_data.NOTEBOOK_PATH.is_file())
        self.assertFalse(
            (_data.NOTEBOOK_PATH.parent / "banking_eda.ipynb.ipynb").exists(),
            "the doubled .ipynb.ipynb extension is back",
        )

    def test_notebook_is_valid_json(self):
        nb = json.loads(_data.NOTEBOOK_PATH.read_text())
        self.assertIn("cells", nb)
        self.assertGreater(len(nb["cells"]), 0)

    def test_no_colab_or_absolute_paths(self):
        offenders = []
        for src in _code_sources():
            for match in DATA_FILE_RE.finditer(src):
                path = match.group(1)
                if path.startswith("/") or path.startswith("~"):
                    offenders.append(path)
        self.assertEqual(
            offenders, [],
            f"notebook references absolute data paths: {offenders}",
        )

    def test_no_reference_to_the_missing_colab_workbook(self):
        joined = "\n".join(_code_sources())
        self.assertNotIn("Banking01.xlsx", joined)

    def test_every_named_data_file_exists_in_the_repo(self):
        """The load path must resolve to a file actually shipped here."""
        repo_root = _data.REPO_ROOT
        search_dirs = [repo_root, repo_root / "python"]
        missing = []
        for src in _code_sources():
            for match in DATA_FILE_RE.finditer(src):
                name = match.group(1)
                if name.startswith("/") or name.startswith("~"):
                    continue  # covered by the absolute-path test
                if not any((d / name).exists() for d in search_dirs):
                    missing.append(name)
        self.assertEqual(missing, [], f"notebook names files that do not exist: {missing}")

    def test_load_cell_handles_the_bom(self):
        """The CSV carries a UTF-8 BOM; the reader must strip it."""
        joined = "\n".join(_code_sources())
        self.assertIn("utf-8-sig", joined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
