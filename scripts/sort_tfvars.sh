#!/bin/bash

set -euo pipefail

# This script sorts the tfvars file alphabetically
sort terraform.tfvars > terraform.tfvars1
rm terraform.tfvars
mv terraform.tfvars1 terraform.tfvars
