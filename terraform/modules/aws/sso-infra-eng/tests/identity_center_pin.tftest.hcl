# Run from the module directory: terraform init -backend=false && terraform test
# The provider is mocked, so no AWS credentials are needed.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }

  mock_data "aws_identitystore_user" {
    defaults = {
      user_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_ssoadmin_permission_set" {
    defaults = {
      arn = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000000"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  environment_name = "test"
}

run "first_apply_records_the_live_instance" {
  command = apply

  override_data {
    target = data.aws_ssoadmin_instances.this
    values = {
      arns               = ["arn:aws:sso:::instance/ssoins-0000000000000000"]
      identity_store_ids = ["d-0000000000"]
    }
  }

  assert {
    condition     = nonsensitive(terraform_data.identity_center_pin.output.identity_store_id) == "d-0000000000"
    error_message = "The first apply must record the live identity store id."
  }
}

run "same_instance_passes_the_check" {
  command = apply

  override_data {
    target = data.aws_ssoadmin_instances.this
    values = {
      arns               = ["arn:aws:sso:::instance/ssoins-0000000000000000"]
      identity_store_ids = ["d-0000000000"]
    }
  }
}

run "replaced_instance_fails_the_check_and_keeps_the_record" {
  command = apply

  override_data {
    target = data.aws_ssoadmin_instances.this
    values = {
      arns               = ["arn:aws:sso:::instance/ssoins-1111111111111111"]
      identity_store_ids = ["d-1111111111"]
    }
  }

  expect_failures = [check.identity_center_instance_matches_pin]

  assert {
    condition     = nonsensitive(terraform_data.identity_center_pin.output.identity_store_id) == "d-0000000000"
    error_message = "A changed live instance must not overwrite the recorded ids."
  }
}
