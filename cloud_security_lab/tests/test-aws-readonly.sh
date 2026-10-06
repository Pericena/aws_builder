#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
MOCK_BIN="$TEMP_DIR/bin"
CALL_LOG="$TEMP_DIR/aws-calls.log"
CALL_ARGS_LOG="$TEMP_DIR/aws-call-args.log"
TEST_PROJECT_DIR="$TEMP_DIR/project"
readonly PROJECT_DIR TEMP_DIR MOCK_BIN CALL_LOG CALL_ARGS_LOG TEST_PROJECT_DIR
readonly ACCOUNT_ID="123456789012"

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -p -- "$MOCK_BIN" "$TEST_PROJECT_DIR/scripts"
cp -- "$PROJECT_DIR/scripts/audit.sh" "$PROJECT_DIR/scripts/load-env.sh" "$TEST_PROJECT_DIR/scripts/"
cat >"$MOCK_BIN/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'aws-cli/2.37.9 Python/3.14.6 Linux/6.17 exe/x86_64\n'
  exit 0
fi
service="$1"
operation="$2"
printf '%s %s\n' "$service" "$operation" >>"$AWS_MOCK_LOG"
printf '%s\n' "$*" >>"$AWS_MOCK_ARGS_LOG"
case "$service:$operation" in
  sts:get-caller-identity)
    printf '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/audit/test","UserId":"test"}\n'
    ;;
  ec2:describe-instances)
    printf '{"Reservations":[{"Instances":[{"InstanceId":"i-test","State":{"Name":"running"},"MetadataOptions":{"HttpEndpoint":"enabled","HttpTokens":"required"},"PublicIpAddress":"198.51.100.20","PrivateIpAddress":"10.0.1.10","VpcId":"vpc-test","SubnetId":"subnet-test","IamInstanceProfile":{"Arn":"arn:aws:iam::123456789012:instance-profile/audit"},"SecurityGroups":[{"GroupId":"sg-demo"}],"BlockDeviceMappings":[{"Ebs":{"VolumeId":"vol-test"}}],"NetworkInterfaces":[{"Ipv6Addresses":[{"Ipv6Address":"2001:db8::20"}]}]}]}]}\n'
    ;;
  ec2:describe-vpcs)
    printf '{"Vpcs":[{"VpcId":"vpc-test","CidrBlock":"10.0.0.0/16","State":"available","IsDefault":false}]}\n'
    ;;
  ec2:describe-subnets)
    printf '{"Subnets":[{"SubnetId":"subnet-test","VpcId":"vpc-test","CidrBlock":"10.0.1.0/24","AvailabilityZone":"us-east-2a","MapPublicIpOnLaunch":false,"AvailableIpAddressCount":240}]}\n'
    ;;
  ec2:describe-route-tables)
    printf '{"RouteTables":[{"RouteTableId":"rtb-test","VpcId":"vpc-test","Associations":[{"SubnetId":"subnet-test","Main":false}],"Routes":[{"DestinationCidrBlock":"0.0.0.0/0","GatewayId":"igw-test","State":"active"},{"DestinationIpv6CidrBlock":"::/0","GatewayId":"igw-test","State":"active"}]}]}\n'
    ;;
  ec2:describe-network-acls)
    printf '{"NetworkAcls":[{"NetworkAclId":"acl-test","VpcId":"vpc-test","IsDefault":true,"Associations":[{"SubnetId":"subnet-test"}],"Entries":[{"RuleNumber":100,"Protocol":"-1","RuleAction":"allow","Egress":false}]}]}\n'
    ;;
  ec2:describe-volumes)
    printf '{"Volumes":[{"VolumeId":"vol-test","Encrypted":true,"State":"in-use"}]}\n'
    ;;
  ec2:describe-security-groups)
    printf '{"SecurityGroups":[{"GroupId":"sg-demo","GroupName":"demo","IpPermissions":[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"0.0.0.0/0"}],"Ipv6Ranges":[{"CidrIpv6":"::/0"}]}]}]}\n'
    ;;
  s3control:get-public-access-block)
    printf '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}\n'
    ;;
  iam:get-account-summary)
    printf '{"SummaryMap":{"AccountMFAEnabled":1,"AccountAccessKeysPresent":0}}\n'
    ;;
  iam:list-users)
    printf '{"Users":[{"UserName":"audit-user","CreateDate":"2026-01-01T00:00:00Z"}]}\n'
    ;;
  iam:list-mfa-devices)
    printf '{"MFADevices":[{"UserName":"audit-user","SerialNumber":"arn:aws:iam::123456789012:mfa/test"}]}\n'
    ;;
  iam:get-login-profile)
    printf '{"LoginProfile":{"UserName":"audit-user"}}\n'
    ;;
  cloudtrail:describe-trails)
    printf '{"trailList":[{"Name":"security-trail","TrailARN":"arn:aws:cloudtrail:us-east-2:123456789012:trail/security-trail","IsMultiRegionTrail":true,"LogFileValidationEnabled":true,"S3BucketName":"audit-logs"}]}\n'
    ;;
  cloudtrail:get-trail-status)
    printf '{"IsLogging":true}\n'
    ;;
  cloudwatch:describe-alarms)
    printf '{"MetricAlarms":[{"AlarmName":"host-health","StateValue":"OK","ActionsEnabled":true}]}\n'
    ;;
  logs:describe-log-groups)
    printf '{"logGroups":[{"logGroupName":"/aws/test","retentionInDays":30}]}\n'
    ;;
  configservice:describe-configuration-recorders)
    printf '{"ConfigurationRecorders":[{"name":"default","recordingGroup":{"allSupported":true}}]}\n'
    ;;
  configservice:describe-configuration-recorder-status)
    printf '{"ConfigurationRecordersStatus":[{"name":"default","recording":true}],"NextToken":null}\n'
    ;;
  guardduty:list-detectors)
    printf '{"DetectorIds":["detector-test"]}\n'
    ;;
  guardduty:get-detector)
    printf '{"Status":"ENABLED"}\n'
    ;;
  securityhub:describe-hub)
    printf '{"HubArn":"arn:aws:securityhub:us-east-2:123456789012:hub/default"}\n'
    ;;
  rds:describe-db-instances)
    printf '{"DBInstances":[]}\n'
    ;;
  s3api:list-buckets)
    printf '{"Buckets":[{"Name":"audit-logs"}]}\n'
    ;;
  s3api:get-bucket-location)
    printf '{"LocationConstraint":"us-east-2"}\n'
    ;;
  s3api:get-public-access-block)
    if [[ -n "${AWS_MOCK_S3_BPA_ERROR:-}" ]]; then
      printf 'An error occurred (%s) when calling the GetPublicAccessBlock operation: Access denied\n' "$AWS_MOCK_S3_BPA_ERROR" >&2
      exit 254
    fi
    printf '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}\n'
    ;;
  s3api:get-bucket-policy-status)
    printf '{"PolicyStatus":{"IsPublic":false}}\n'
    ;;
  s3api:get-bucket-encryption)
    printf '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}\n'
    ;;
  s3api:get-bucket-versioning)
    printf '{"Status":"Enabled"}\n'
    ;;
  s3api:get-bucket-logging)
    printf '{"LoggingEnabled":{"TargetBucket":"audit-logs-destination"}}\n'
    ;;
  *)
    printf 'Unexpected AWS CLI operation: %s %s\n' "$service" "$operation" >&2
    exit 64
    ;;
esac
MOCK_AWS
chmod 700 "$MOCK_BIN/aws"

export AWS_MOCK_LOG="$CALL_LOG"
export AWS_MOCK_ARGS_LOG="$CALL_ARGS_LOG"
export AWS_REGION="us-west-1"
export AWS_EXPECTED_ACCOUNT_ID="$ACCOUNT_ID"
export PATH="$MOCK_BIN:$PATH"

if output="$(bash "$TEST_PROJECT_DIR/scripts/audit.sh" --region us-east-2)"; then
  audit_status=0
else
  audit_status=$?
fi
[[ "$audit_status" -eq 0 || "$audit_status" -eq 2 ]] || {
  printf '%s\n' "$output" >&2
  printf 'FAIL: audit exited unexpectedly with %s.\n' "$audit_status" >&2
  exit 1
}

report_path="$(sed -n 's/^REPORT_JSON=//p' <<<"$output" | tail -n 1)"
[[ -f "$report_path" ]] || {
  printf '%s\n' "$output" >&2
  printf 'FAIL: audit did not create report.json.\n' >&2
  exit 1
}
for phase in "PASO 2/4" "PASO 3/4" "PASO 3.1" "PASO 3.3" "PASO 3.4" "PASO 3.5" "PASO 3.6" "PASO 4/4"; do
  grep -Fq "$phase" <<<"$output" || {
    printf 'FAIL: missing guided phase %s in audit output.\n' "$phase" >&2
    exit 1
  }
done
grep -Eq 'PASS [0-9]+.*WARN [0-9]+.*FAIL [0-9]+.*ERROR/sin verificar [0-9]+' <<<"$output" || {
  printf 'FAIL: audit did not print numeric status counts.\n' >&2
  exit 1
}
grep -Eq '^cloudtrail describe-trails .*--region us-east-2([[:space:]]|$)' "$CALL_ARGS_LOG" || {
  printf 'FAIL: CloudTrail describe-trails did not use the selected --region override.\n' >&2
  exit 1
}
grep -Eq '^cloudtrail get-trail-status .*--region us-east-2([[:space:]]|$)' "$CALL_ARGS_LOG" || {
  printf 'FAIL: CloudTrail get-trail-status did not use the selected --region override.\n' >&2
  exit 1
}
jq -e --arg account_suffix "${ACCOUNT_ID: -4}" '
  .read_only == true
  and .scope.aws_region == "us-east-2"
  and .scope.aws_s3_scope == "all-account-buckets"
  and .scope.aws_account_id_suffix == $account_suffix
  and ([.checks[] | select(.scope=="AWS" and .status=="ERROR")] | length) == 0
  and ([.checks[] | select(.control=="EC2-IMDSV2" and .status=="PASS")] | length) == 1
  and ([.checks[] | select(.control=="IAM-CONSOLE-MFA" and .status=="PASS")] | length) == 1
  and ([.checks[] | select(.control=="S3-ACCOUNT-PUBLIC-ACCESS-BLOCK" and .status=="PASS")] | length) == 1
  and ([.checks[] | select(.control=="S3-PUBLIC-POLICY" and .status=="PASS")] | length) == 1
  and ([.checks[] | select(.control=="CLOUDTRAIL-LOGGING" and .status=="PASS")] | length) == 1
  and ([.checks[] | select(.control=="HOST-SHADOW-PERMISSIONS" and .status=="PASS")] | length) == 1
  and ([.checks[] | select(.control=="EC2-SG-PUBLIC-INGRESS" and .status=="FAIL")] | length) == 2
  and ([.checks[] | select(.control=="EC2-IAM-INSTANCE-PROFILE" and .status=="INFO")] | length) == 1
  and ([.checks[] | select(.control=="EC2-NETWORK-PATH" and .status=="WARN")] | length) == 1
  and ([.checks[] | select(.control=="EC2-PUBLIC-IPV6" and .status=="INFO")] | length) == 1
  and (.inventory.vpcs[0].vpc_id == "vpc-test")
  and (.inventory.subnets[0].subnet_id == "subnet-test")
  and (.inventory.route_tables[0].default_ipv4_internet_gateway_route == true)
  and (.inventory.route_tables[0].default_ipv6_internet_gateway_route == true)
  and (.inventory.route_tables[0].routes[0].gateway_id == "igw-test")
  and (.inventory.network_acls[0].network_acl_id == "acl-test")
  and (.inventory.network_acls[0].entries[0].rule_number == 100)
  and (.inventory.security_groups[0].ingress[0].ipv4_cidrs == ["0.0.0.0/0"])
  and (.inventory["ec2_instance:i-test"].security_group_ids == ["sg-demo"])
  and (.inventory["ec2_instance:i-test"].public_ipv4 == "198.51.100.20")
  and (.inventory["ec2_instance:i-test"].ipv6_addresses == ["2001:db8::20"])
  and (.inventory.cloudwatch_alarms[0].name == "host-health")
  and (.inventory.cloudwatch_log_groups[0].retention_days == 30)
' "$report_path" >/dev/null

(cd "$(dirname "$report_path")" && sha256sum -c SHA256SUMS) >/dev/null

if grep -Eq '(^|[[:space:]])(create|put|delete|terminate|stop|start|modify|authorize|revoke|update|enable|disable|run|launch|attach|detach|remove|install|uninstall|generate|start|restore|copy|cancel)[a-z-]*([[:space:]]|$)' "$CALL_LOG"; then
  printf 'FAIL: mock observed a mutating AWS operation.\n' >&2
  exit 1
fi

printf 'PASS: AWS inventory, public ingress detection, S3, IAM, CloudTrail and read-only API allowlist.\n'

export AWS_MOCK_S3_BPA_ERROR="AccessDenied"
if bpa_error_output="$(bash "$TEST_PROJECT_DIR/scripts/audit.sh")"; then
  bpa_error_status=0
else
  bpa_error_status=$?
fi
[[ "$bpa_error_status" -eq 0 || "$bpa_error_status" -eq 2 ]] || {
  printf '%s\n' "$bpa_error_output" >&2
  printf 'FAIL: S3 access-block error audit exited unexpectedly with %s.\n' "$bpa_error_status" >&2
  exit 1
}
bpa_error_report="$(sed -n 's/^REPORT_JSON=//p' <<<"$bpa_error_output" | tail -n 1)"
[[ -f "$bpa_error_report" ]] || {
  printf 'FAIL: S3 access-block error audit did not create report.json.\n' >&2
  exit 1
}
jq -e '
  .inventory["s3_bucket:audit-logs"].public_access_block_all_enabled == null
  and ([.checks[] | select(.control=="S3-PUBLIC-ACCESS-BLOCK" and .status=="ERROR")] | length) == 1
' "$bpa_error_report" >/dev/null || {
  printf 'FAIL: an unreadable S3 access block was reported as disabled instead of unknown.\n' >&2
  exit 1
}
unset AWS_MOCK_S3_BPA_ERROR
printf 'PASS: unreadable S3 public-access settings remain unknown in inventory.\n'

printf '' >"$CALL_LOG"
export AWS_EXPECTED_ACCOUNT_ID="999999999999"
if mismatch_output="$(bash "$TEST_PROJECT_DIR/scripts/audit.sh")"; then
  mismatch_status=0
else
  mismatch_status=$?
fi
[[ "$mismatch_status" -eq 0 || "$mismatch_status" -eq 2 ]] || {
  printf '%s\n' "$mismatch_output" >&2
  printf 'FAIL: account guard exited unexpectedly with %s.\n' "$mismatch_status" >&2
  exit 1
}
mismatch_report="$(sed -n 's/^REPORT_JSON=//p' <<<"$mismatch_output" | tail -n 1)"
[[ -f "$mismatch_report" ]] || {
  printf 'FAIL: account guard did not produce an audit record.\n' >&2
  exit 1
}
jq -e '[.checks[] | select(.control=="AWS-EXPECTED-ACCOUNT" and .status=="FAIL")] | length == 1' "$mismatch_report" >/dev/null
[[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" == "1" ]] || {
  printf 'FAIL: AWS queries continued after account mismatch.\n' >&2
  exit 1
}
[[ "$(cat "$CALL_LOG")" == "sts get-caller-identity" ]] || {
  printf 'FAIL: an unexpected API was called before account validation.\n' >&2
  exit 1
}
printf 'PASS: account mismatch guard stops before any regional or service query.\n'

printf '' >"$CALL_LOG"
cat >"$MOCK_BIN/aws" <<'MOCK_AWS_V1'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'aws-cli/1.32.0 Python/3.11 Linux/6.1\n'
  exit 0
fi
exit 64
MOCK_AWS_V1
chmod 700 "$MOCK_BIN/aws"
if v1_output="$(bash "$TEST_PROJECT_DIR/scripts/audit.sh" 2>&1)"; then
  v1_status=0
else
  v1_status=$?
fi
[[ "$v1_status" -eq 1 ]] || {
  printf '%s\n' "$v1_output" >&2
  printf 'FAIL: AWS CLI v1 was not rejected before the audit.\n' >&2
  exit 1
}
grep -Fq 'Se requiere AWS CLI v2' <<<"$v1_output" || {
  printf 'FAIL: the AWS CLI v1 rejection was not explained.\n' >&2
  exit 1
}
[[ ! -s "$CALL_LOG" ]] || {
  printf 'FAIL: AWS service calls occurred with AWS CLI v1.\n' >&2
  exit 1
}
printf 'PASS: AWS CLI v1 is rejected before AWS service calls.\n'
