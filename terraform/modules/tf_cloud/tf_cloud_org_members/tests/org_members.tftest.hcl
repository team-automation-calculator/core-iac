# Run from the module directory: terraform init -backend=false && terraform test
# The provider is mocked, so no TFE_TOKEN is needed.
mock_provider "tfe" {}

variables {
  organization_name = "example-org"
}

run "no_members_creates_nothing" {
  command = plan

  assert {
    condition     = length(tfe_organization_membership.member) == 0
    error_message = "An empty members map must not create memberships."
  }

  assert {
    condition     = length(data.tfe_team.owners) == 0
    error_message = "The owners team must not be read when there are no owners."
  }
}

run "owners_and_plain_members" {
  command = apply

  variables {
    members = {
      ci    = { email = "ci@example.com" }
      human = { email = "human@example.com", owner = true }
    }
  }

  assert {
    condition     = length(tfe_organization_membership.member) == 2
    error_message = "Each entry must get an organization membership."
  }

  assert {
    condition     = keys(tfe_team_organization_member.owner) == ["human"]
    error_message = "Only members with owner = true join the owners team."
  }

  assert {
    condition     = output.members["ci"].owner == false && output.members["human"].owner == true
    error_message = "The members output must report owner status."
  }
}

run "rejects_duplicate_email" {
  command = plan

  variables {
    members = {
      a = { email = "same@example.com" }
      b = { email = "Same@example.com" }
    }
  }

  expect_failures = [var.members]
}

run "rejects_malformed_email" {
  command = plan

  variables {
    members = {
      a = { email = "not-an-address" }
    }
  }

  expect_failures = [var.members]
}
