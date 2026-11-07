"""Tests for added_versions in scripts/check_app_docker_image_versions.py.

Since ArgoCD migration Phase 1 the image tag lives in the chart values files
(`image.tag` in helm/automation-calculator/values.yaml and values-<env>.yaml),
not in terraform.tfvars, so the diffs below are values-file diffs.
"""

from check_app_docker_image_versions import added_versions

DIFF = """\
diff --git a/helm/automation-calculator/values-staging.yaml b/helm/automation-calculator/values-staging.yaml
index 1111111..2222222 100644
--- a/helm/automation-calculator/values-staging.yaml
+++ b/helm/automation-calculator/values-staging.yaml
@@ -1,6 +1,6 @@
 image:
-  tag: 0.9.6-989
+  tag: 0.9.6-990
 shortCommitHash: "a678335"
"""


def test_extracts_added_version():
    assert added_versions(DIFF) == ["0.9.6-990"]


def test_empty_diff_has_no_versions():
    assert added_versions("") == []


def test_removed_and_context_lines_are_ignored():
    diff = "-  tag: 0.9.6-989\n   tag: 0.9.6-988\n"
    assert added_versions(diff) == []


def test_file_header_lines_are_not_versions():
    diff = "+++ b/helm/automation-calculator/values.yaml\n--- a/values.yaml\n"
    assert added_versions(diff) == []


def test_quoted_and_spacing_variants_match():
    diff = '+  tag: "1.0.0"\n+    tag:   1.0.1\n'
    assert added_versions(diff) == ["1.0.0", "1.0.1"]


def test_trailing_comment_after_value_is_ignored():
    assert added_versions("+  tag: 1.0.0 # bumped\n") == ["1.0.0"]


def test_top_level_or_other_keys_do_not_match():
    # image.tag is always indented under `image:`; an unindented `tag:` or a key
    # that merely ends in "tag" is something else.
    diff = "+tag: 1.0.0\n+  imageTag: 1.0.1\n+  pullPolicy: Always\n"
    assert added_versions(diff) == []


def test_commented_out_line_does_not_match():
    assert added_versions("+  # tag: 1.0.0\n") == []


def test_duplicates_across_environments_are_collapsed():
    diff = "+  tag: 0.9.6-990\n+  tag: 0.9.6-990\n"
    assert added_versions(diff) == ["0.9.6-990"]


def test_result_is_sorted_as_strings_not_versions():
    diff = "+  tag: 0.9.6-990\n+  tag: 0.9.6-1000\n"
    # Lexicographic: "1000" sorts before "990". Order only affects output order.
    assert added_versions(diff) == ["0.9.6-1000", "0.9.6-990"]
