#!/usr/bin/env bash
set -euo pipefail

# Load .env
set -a; source .env; set +a

MIN_TASKS=2
MAX_TASKS=10
CLUSTER_NAME="concert-platform-booking-cluster"
SERVICE_NAME="concert-platform-booking"
QUEUE_CLUSTER_NAME="concert-platform-queue-cluster"
QUEUE_SERVICE_NAME="concert-platform-queue"
BACKEND="mysql"
ADMISSION_RATE=50

STEP_AGGRESSIVE='[{"metric_interval_lower_bound":0,"metric_interval_upper_bound":10,"scaling_adjustment":2},{"metric_interval_lower_bound":10,"metric_interval_upper_bound":15,"scaling_adjustment":4},{"metric_interval_lower_bound":15,"scaling_adjustment":6}]'
STEP_CONSERVATIVE='[{"metric_interval_lower_bound":0,"metric_interval_upper_bound":10,"scaling_adjustment":1},{"metric_interval_lower_bound":10,"metric_interval_upper_bound":25,"scaling_adjustment":2},{"metric_interval_lower_bound":25,"scaling_adjustment":3}]'

stop_experiment() {
    echo "ERROR: $1"
    kill "${WORKER_PIDS[@]}" 2>/dev/null || true
    exit 1
}

apply_terraform() {
    local name="$1" policy_type="$2" out_cool="$3" in_cool="$4"
    local target_cpu="${5:-70}" alarm="${6:-70}" step_json="${7:-}"

    echo "Applying scaling configuration: $name"
    local base_vars="-var autoscaling_min=${MIN_TASKS} -var autoscaling_max=${MAX_TASKS} -var scaling_policy_type=${policy_type} -var db_backend=${BACKEND} -var admission_rate=${ADMISSION_RATE}"

    if [[ "$policy_type" == "target_tracking" ]]; then
        terraform -chdir=../../terraform/main apply $base_vars \
            -var "scale_out_cooldown=${out_cool}" \
            -var "scale_in_cooldown=${in_cool}" \
            -var "autoscaling_cpu_target=${target_cpu}" \
            -auto-approve
    elif [[ "$policy_type" == "step" ]]; then
        terraform -chdir=../../terraform/main apply $base_vars \
            -var "scale_out_cooldown=${out_cool}" \
            -var "scale_in_cooldown=${in_cool}" \
            -var "autoscaling_cpu_target=${target_cpu}" \
            -var "alarm_cpu_threshold=${alarm}" \
            -var "step_adjustments=${step_json}" \
            -auto-approve
    elif [[ "$policy_type" == "none" ]]; then
        terraform -chdir=../../terraform/main apply $base_vars -auto-approve
    fi

    [[ $? -eq 0 ]] || stop_experiment "Terraform apply failed for: $name"
}

reset_services() {
    local config="$1" run="$2"
    aws ecs update-service --cluster "$QUEUE_CLUSTER_NAME" --service "$QUEUE_SERVICE_NAME" --force-new-deployment > /dev/null \
        || stop_experiment "Failed to redeploy queue service ($config, run $run)"
    aws ecs wait services-stable --cluster "$QUEUE_CLUSTER_NAME" --services "$QUEUE_SERVICE_NAME" \
        || stop_experiment "Queue service failed to stabilize ($config, run $run)"

    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count "$MIN_TASKS" > /dev/null \
        || stop_experiment "Failed to reset booking service count ($config, run $run)"
    aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
        || stop_experiment "Booking service failed to stabilize ($config, run $run)"

    curl -sf -X POST "http://${ALB}/booking/api/v1/reset"
}

mkdir -p results

echo "Starting EC2 instances"
mapfile -t INSTANCE_IDS < <(aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=locust-worker" "Name=instance-state-name,Values=stopped,running" \
    --query "Reservations[*].Instances[*].InstanceId" --output text | tr '\t' '\n')

aws ec2 start-instances --instance-ids "${INSTANCE_IDS[@]}" > /dev/null
aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_IDS[@]}"

mapfile -t ALL_IPS < <(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_IDS[@]}" \
    --query "Reservations[*].Instances[*].PublicIpAddress" --output text | tr '\t' '\n')

EC2="${ALL_IPS[0]}"
WORKERS=("${ALL_IPS[@]:1}")
echo "Locust master: $EC2  Workers: ${WORKERS[*]}"

run_config() {
    local config="$1"

    echo "Waiting for scaling policy to stabilize"
    echo "Redeploying services for clean slate"
    reset_services "$config" "pre"

    for i in 1; do
        echo "Starting Locust workers for config: $config, run: $i"
        WORKER_PIDS=()
        for worker in "${WORKERS[@]}"; do
            ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@${worker}" \
                "~/.local/bin/locust -f locustfile.py --host=http://${ALB} --worker --master-host=${EC2}" &
            WORKER_PIDS+=($!)
            sleep 5
        done

        sleep 5
        echo "Running experiment: $config, run $i"
        ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@${EC2}" \
            "pkill -f locust; sleep 2"
        ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@${EC2}" \
            "~/.local/bin/locust -f locustfile.py --host=http://${ALB} --headless --master --csv=results_${config}_run${i} --expect-workers=4"
        scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
            "ec2-user@${EC2}:~/results_${config}_run${i}*" ./results/

        kill "${WORKER_PIDS[@]}" 2>/dev/null || true
        wait "${WORKER_PIDS[@]}" 2>/dev/null || true

        echo "Resetting for next run"
        reset_services "$config" "$i"
    done
}

apply_terraform "target-tracking-aggressive" "target_tracking" 30 120 70
run_config "target-tracking-aggressive"

apply_terraform "target-tracking-conservative" "target_tracking" 120 120 70
run_config "target-tracking-conservative"

apply_terraform "step-aggressive" "step" 30 120 70 70 "$STEP_AGGRESSIVE"
run_config "step-aggressive"

apply_terraform "step-conservative" "step" 120 120 70 70 "$STEP_CONSERVATIVE"
run_config "step-conservative"

apply_terraform "no-scaling" "none" 0 0
run_config "no-scaling"

echo "Stopping EC2 instances"
aws ec2 stop-instances --instance-ids "${INSTANCE_IDS[@]}" > /dev/null
echo "Done."
