"""Tests for added_versions in scripts/check_app_docker_image_versions.py."""

from check_app_docker_image_versions import added_versions

DIFF = """\
diff --git a/terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars b/terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars
index 1111111..2222222 100644
--- a/terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars
+++ b/terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars
@@ -1,3 +1,3 @@
 automation_calculator_app_host = "staging.automation-calculations.io"
-app_version                    = "0.9.6-989"
+app_version                    = "0.9.6-990"
 cluster_name                   = "ac_app_staging"
"""


def test_extracts_added_version():
    assert added_versions(DIFF) == ["0.9.6-990"]


def test_empty_diff_has_no_versions():
    assert added_versions("") == []


def test_removed_and_context_lines_are_ignored():
    diff = '-app_version = "0.9.6-989"\n app_version = "0.9.6-988"\n'
    assert added_versions(diff) == []


def test_file_header_lines_are_not_versions():
    assert added_versions("+++ b/terraform.tfvars\n--- a/terraform.tfvars\n") == []


def test_whitespace_variants_match():
    diff = '+app_version="1.0.0"\n+  app_version   =   "1.0.1"\n'
    assert added_versions(diff) == ["1.0.0", "1.0.1"]


def test_trailing_comment_after_value_is_ignored():
    assert added_versions('+app_version = "1.0.0" # bumped\n') == ["1.0.0"]


def test_other_variables_with_shared_prefix_do_not_match():
    diff = '+app_version_previous = "1.0.0"\n+my_app_version = "1.0.1"\n'
    assert added_versions(diff) == []


def test_commented_out_line_does_not_match():
    assert added_versions('+# app_version = "1.0.0"\n') == []


def test_unquoted_value_does_not_match():
    assert added_versions("+app_version = var.version\n") == []


def test_duplicates_across_environments_are_collapsed():
    diff = '+app_version = "0.9.6-990"\n+app_version = "0.9.6-990"\n'
    assert added_versions(diff) == ["0.9.6-990"]


def test_result_is_sorted_as_strings_not_versions():
    diff = '+app_version = "0.9.6-990"\n+app_version = "0.9.6-1000"\n'
    # Lexicographic: "1000" sorts before "990". Order only affects output order.
    assert added_versions(diff) == ["0.9.6-1000", "0.9.6-990"]
