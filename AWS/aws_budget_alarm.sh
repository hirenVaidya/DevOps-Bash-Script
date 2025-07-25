#!/usr/bin/env bash
set -euo pipefail

# Directory of the script
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source AWS helper functions (if available)
if [[ -f "$srcdir/lib/aws.sh" ]]; then
  . "$srcdir/lib/aws.sh"
fi

# Usage function
usage() {
  echo "Usage: $0 <budget_amount_in_USD> [<email_address>]"
  exit 1
}

# Get arguments
budget="${1:-0.01}"
email="${2:-$(git config user.email || :)}"
region="us-east-1"
sns_topic="AWS_Charges"

# Validate arguments
if ! [[ "$budget" =~ ^[[:digit:]]{1,4}(\.[[:digit:]]{1,2})?$ ]]; then
  echo "ERROR: Invalid budget argument given - must be 0.01 - 9999.99 USD"
  usage
fi

if [[ -z "$email" ]]; then
  echo "ERROR: Email address not specified and could not determine email from git config"
  usage
fi

echo "Creating SNS topic '$sns_topic' in region '$region'..."
output="$(aws sns create-topic --name "$sns_topic" --region "$region" --output json)"
sns_topic_arn="$(jq -r '.TopicArn' <<< "$output")"
echo "SNS Topic ARN: $sns_topic_arn"

echo "Subscribing email address '$email' to topic '$sns_topic'..."
aws sns subscribe --topic-arn "$sns_topic_arn" --protocol email --notification-endpoint "$email" --region "$region"

echo "Getting AWS account ID..."
account_id="$(aws sts get-caller-identity --query Account --output text)"
echo "Account ID: $account_id"

# Prepare policy file for SNS access
policy_file="$srcdir/aws_budget_sns_access_policy.json"
if [[ ! -f "$policy_file" ]]; then
  echo "ERROR: Policy file '$policy_file' not found."
  exit 1
fi

policy_json="$(sed "s|<AWS_SNS_ARN>|$sns_topic_arn|g; s|<AWS_ACCOUNT_ID>|$account_id|g" "$policy_file")"

echo "Updating SNS topic policy to allow AWS Budgets to publish notifications..."
aws sns set-topic-attributes --topic-arn "$sns_topic_arn" --attribute-name Policy --attribute-value "$policy_json" --region "$region"

# Check for existing budgets
echo "Checking for existing AWS Budgets..."
budgets="$(aws budgets describe-budgets --account-id "$account_id" --query 'Budgets[*].BudgetName' --output text)"

# Read budget name from JSON template
budget_json_file="$srcdir/aws_budget.json"
if [[ ! -f "$budget_json_file" ]]; then
  echo "ERROR: Budget JSON file '$budget_json_file' not found."
  exit 1
fi

budget_name="$(jq -r .BudgetName < "$budget_json_file")"

if grep -Fxq "$budget_name" <<< "$budgets"; then
  echo "AWS Budget '$budget_name' already exists."
  if [[ -n "${REPLACE_BUDGET:-}" ]]; then
    echo "Deleting existing budget '$budget_name' to replace it..."
    aws budgets delete-budget --account-id "$account_id" --budget-name "$budget_name"
  else
    echo "Set REPLACE_BUDGET=1 to delete and recreate the budget."
    exit 0
  fi
fi

# Prepare budget and notification JSON with correct values
budget_json="$(sed "s|<AWS_BUDGET_AMOUNT>|$budget|g" "$budget_json_file")"

notification_json_file="$srcdir/aws_budget_notification.json"
if [[ ! -f "$notification_json_file" ]]; then
  echo "ERROR: Notification JSON file '$notification_json_file' not found."
  exit 1
fi

notification_json="$(sed "s|<AWS_SNS_ARN>|$sns_topic_arn|g" "$notification_json_file")"

echo "Creating AWS Budget with $budget USD budget and SNS notifications..."
aws budgets create-budget \
  --account-id "$account_id" \
  --budget "$budget_json" \
  --notifications-with-subscribers "$notification_json"

echo "AWS Budget and notifications set up successfully!"
echo "You can view your budget here:"
echo "  https://console.aws.amazon.com/billing/home#/budgets/overview"