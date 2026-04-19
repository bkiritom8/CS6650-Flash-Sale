#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load .env
set -a; source "${SCRIPT_DIR}/../experiments/experiment3/.env"; set +a

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)
MY_IP=$(curl -sf https://api.ipify.org)

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=locust-sg" \
    --query "SecurityGroups[0].GroupId" --output text)

if [[ "$SG_ID" == "None" ]]; then
    echo "Creating security group"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "locust-sg" \
        --description "Security group for Locust EC2 instances" \
        --vpc-id "$VPC_ID" --query "GroupId" --output text)
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22   --cidr "${MY_IP}/32"
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 5557 --source-group "$SG_ID"
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 5558 --source-group "$SG_ID"
fi

AMI_ID=$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

echo "Launching 5 EC2 instances (AMI: $AMI_ID)"
aws ec2 run-instances \
    --image-id "$AMI_ID" --count 5 --instance-type t2.micro \
    --key-name "cs6650-hw1b" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Role,Value=locust-worker}]' \
    --security-group-ids "$SG_ID" > /dev/null

INSTANCE_IDS=()
while IFS= read -r line; do [[ -n "$line" ]] && INSTANCE_IDS+=("$line"); done < <(aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=locust-worker" "Name=instance-state-name,Values=stopped,running" \
    --query "Reservations[*].Instances[*].InstanceId" --output text | tr '\t' '\n')

echo "Waiting for instances to be ready..."
aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_IDS[@]}"

EC2_IPS=()
while IFS= read -r line; do [[ -n "$line" ]] && EC2_IPS+=("$line"); done < <(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_IDS[@]}" \
    --query "Reservations[*].Instances[*].PublicIpAddress" --output text | tr '\t' '\n')

echo "Installing Locust on all instances in parallel..."
PIDS=()
for instance in "${EC2_IPS[@]}"; do
    echo "  Setting up $instance"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@${instance}" \
        "sudo yum update -y && sudo yum install -y python3 python3-pip && pip3 install locust 'urllib3<2.0' --user" &
    PIDS+=($!)
done
wait "${PIDS[@]}"

echo "Uploading locustfile.py to all instances..."
for instance in "${EC2_IPS[@]}"; do
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
        "${SCRIPT_DIR}/../experiments/experiment3/locustfile.py" "ec2-user@${instance}:~/locustfile.py"
done

echo "Done. Instance IDs:"
aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=locust-worker" "Name=instance-state-name,Values=stopped,running" \
    --query "Reservations[*].Instances[*].InstanceId" --output text
