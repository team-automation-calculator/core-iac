"""Tests for scripts/rds_price_list_extract.py: row filtering on a tiny fake price
list, and that LOG_LEVEL=WARNING suppresses the INFO row count on stderr while
leaving stdout unchanged."""

import os
import pathlib
import subprocess
import sys

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / (
    "scripts/rds_price_list_extract.py"
)

HEADER = (
    '"TermType","LeaseContractLength","PurchaseOption","Product Family",'
    '"Instance Type","vCPU","Memory","Database Engine","Deployment Option",'
    '"Volume Type","usageType","Unit","PricePerUnit","StartingRange","EndingRange",'
    '"Normalization Size Factor","PriceDescription"'
)
ROWS = [
    (
        '"OnDemand","","","Database Instance","db.t4g.micro","2","1 GiB","PostgreSQL",'
        '"Single-AZ","","USW1-InstanceUsg:db.t4g.micro","Hrs","0.0180","0","Inf",'
        '"0.5","micro row"'
    ),
    (
        '"OnDemand","","","Database Instance","db.t4g.small","2","2 GiB","MySQL",'
        '"Single-AZ","","USW1-InstanceUsg:db.t4g.small","Hrs","0.0360","0","Inf",'
        '"1","small row"'
    ),
]


@pytest.fixture
def price_csv(tmp_path):
    path = tmp_path / "index.csv"
    preamble = [f'"Preamble{i}","x"' for i in range(5)]
    path.write_text("\n".join(preamble + [HEADER] + ROWS) + "\n", encoding="utf-8")
    return path


def run(csv_path, *args, log_level=None):
    env = {k: v for k, v in os.environ.items() if k != "LOG_LEVEL"}
    if log_level is not None:
        env["LOG_LEVEL"] = log_level
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), str(csv_path), *args],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )


def test_engine_filter(price_csv):
    result = run(price_csv, "--engine", "PostgreSQL")
    lines = result.stdout.splitlines()
    assert len(lines) == 1
    assert "db.t4g.micro" in lines[0]
    assert "INFO: -- 1 rows" in result.stderr


def test_log_level_warning_suppresses_info(price_csv):
    default = run(price_csv)
    quiet = run(price_csv, log_level="WARNING")
    assert "INFO: -- 2 rows" in default.stderr
    assert quiet.stderr == ""
    assert quiet.stdout == default.stdout
