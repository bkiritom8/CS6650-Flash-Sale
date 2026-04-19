Get-Content .env | ForEach-Object {
    $key, $value = $_ -split '=', 2
    Set-Variable -Name $key -Value $value
}

$instance_ids = (aws ec2 describe-instances --filters "Name=tag:Role,Values=locust-worker" "Name=instance-state-name,Values=stopped,running" --query "Reservations[*].Instances[*].InstanceId" --output text).Split()

$host_name = $ALB
#Write-Host "Running tests pointed at ALB: $ALB"
$min_tasks = 2
$max_tasks = 10
$cluster_name = "concert-platform-booking-cluster"
$service_name = "concert-platform-booking"
$queue_cluster_name = "concert-platform-queue-cluster"
$queue_service_name = "concert-platform-queue"
$backend = "mysql"
$admission_rate = 100


$configurations = @(
    @{name = "target-tracking-aggressive"
    scaling_policy_type = "target_tracking"
    scale_out_cooldown = 30
    scale_in_cooldown = 120
    target_cpu = 70
}, @{
    name = "target-tracking-conservative"
    scaling_policy_type = "target_tracking"
    scale_out_cooldown = 120
    scale_in_cooldown = 120
    target_cpu = 70
}, @{
    name = "step-aggressive"
    scaling_policy_type = "step"
    scale_out_cooldown = 30
    scale_in_cooldown = 120
    alarm = 70
    step_adjustments = @(
        @{
            metric_interval_lower_bound = 0
            metric_interval_upper_bound = 10
            scaling_adjustment = 2
        },
        @{
            metric_interval_lower_bound = 10
            metric_interval_upper_bound = 15
            scaling_adjustment = 4
        },
        @{
            metric_interval_lower_bound = 15
            scaling_adjustment = 6
        }
    )
}, @{
    name = "step-conservative"
    scaling_policy_type = "step"
    scale_out_cooldown = 120
    scale_in_cooldown = 120
    alarm = 70
    step_adjustments = @(
        @{
            metric_interval_lower_bound = 0
            metric_interval_upper_bound = 10
            scaling_adjustment = 1
        },
        @{
            metric_interval_lower_bound = 10
            metric_interval_upper_bound = 25
            scaling_adjustment = 2
        },
        @{
            metric_interval_lower_bound = 25
            scaling_adjustment = 3
        }
    )
}, @{
    name = "no-scaling"
    scaling_policy_type = "none"
})

function Stop-Experiment {
    param($jobs, $message)
    Write-Host $message
    $jobs | Stop-Job
    $jobs | Remove-Job
    exit 1
}

New-Item -ItemType Directory -Force ./results
Write-Host "Starting EC2 instances"
# Start EC2 instances and get their public IPs
aws ec2 start-instances --instance-ids $instance_ids | Out-Null
aws ec2 wait instance-status-ok --instance-ids $instance_ids | Out-Null
$all_ips = (aws ec2 describe-instances --instance-ids $instance_ids --query "Reservations[*].Instances[*].PublicIpAddress" --output text).Split()
$EC2 = $all_ips[0] # Use the first instance as the Locust master
Write-Host "Locust master running on EC2 instance with IP: $EC2"
$EC2_workers = $all_ips[1..($all_ips.Length - 1)]


# Run the experiment for each configuration
foreach ($config in $configurations) {
    # Determine configuration and apply terraform
    $configuration = $config.name
    Write-Host "Creating auto-scaling policy configuration: $configuration"
    if ($config.scaling_policy_type -eq "target_tracking") {
        $cmd = "terraform '-chdir=../../terraform/main' apply -var 'autoscaling_min=${min_tasks}' -var 'autoscaling_max=${max_tasks}' -var 'scaling_policy_type=${config.scaling_policy_type}' -var 'scale_out_cooldown=${config.scale_out_cooldown}' -var 'scale_in_cooldown=${config.scale_in_cooldown}' -var 'autoscaling_cpu_target=${config.target_cpu}' -var 'db_backend=${backend}' -var 'admission_rate=${admission_rate}' -auto-approve"
        Write-Host "Applying terraform configuration with command: $cmd"
        terraform "-chdir=../../terraform/main" apply -var "autoscaling_min=${min_tasks}" -var "autoscaling_max=${max_tasks}" -var "scaling_policy_type=$($config.scaling_policy_type)" -var "scale_out_cooldown=$($config.scale_out_cooldown)" -var "scale_in_cooldown=$($config.scale_in_cooldown)" -var "autoscaling_cpu_target=$($config.target_cpu)" -var "db_backend=${backend}" -var "admission_rate=${admission_rate}" -auto-approve
    } elseif ($config.scaling_policy_type -eq "step") {
        $json = $config.step_adjustments | ConvertTo-Json -Compress
        terraform "-chdir=../../terraform/main" apply -var "autoscaling_min=${min_tasks}" -var "autoscaling_max=${max_tasks}" -var "scaling_policy_type=$($config.scaling_policy_type)" -var "scale_out_cooldown=$($config.scale_out_cooldown)" -var "scale_in_cooldown=$($config.scale_in_cooldown)" -var "autoscaling_cpu_target=$($config.target_cpu)" -var "alarm_cpu_threshold=$($config.alarm)" -var "step_adjustments=${json}" -var "db_backend=${backend}" -var "admission_rate=${admission_rate}" -auto-approve
    } elseif ($config.scaling_policy_type -eq "none") {
        terraform "-chdir=../../terraform/main" apply -var "autoscaling_min=${min_tasks}" -var "autoscaling_max=${max_tasks}" -var "scaling_policy_type=$($config.scaling_policy_type)" -var "db_backend=${backend}" -var "admission_rate=${admission_rate}" -auto-approve
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-Experiment -jobs $jobs -message "Failed to apply scaling configuration: $configuration. Stopping experiment."
    }
    Write-Host "Waiting for scaling policy to stabilize"
    
    # Ensure services are starting from a clean slate by forcing redeployment and waiting for healthy status before starting the experiment
    Write-Host "Redeploying services to ensure a clean slate for the experiment"
    aws ecs update-service --cluster $queue_cluster_name --service $queue_service_name --force-new-deployment | Out-Null # Force redeploy queue service to clear any queued requests
    if ($LASTEXITCODE -ne 0) {
        Stop-Experiment -jobs $jobs -message "Failed to update queue service for configuration: $configuration, run: $i. Stopping experiment."
    }
    aws ecs wait services-stable --cluster $queue_cluster_name --services $queue_service_name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Experiment -jobs $jobs -message "Failed to reach stable state for queue service during reset for configuration: $configuration, run: $i. Stopping experiment."
    }
    aws ecs update-service --cluster $cluster_name --service $service_name --desired-count $min_tasks | Out-Null # Ensure we start from the minimum number of tasks
    if ($LASTEXITCODE -ne 0) {
        Stop-Experiment -jobs $jobs -message "Failed to update service for configuration: $configuration. Stopping experiment."
    }
    aws ecs wait services-stable --cluster $cluster_name --services $service_name | Out-Null # Wait for the scaling policy to take effect
     if ($LASTEXITCODE -ne 0) {
        Stop-Experiment -jobs $jobs -message "Failed to reach stable state for configuration: $configuration. Stopping experiment."
    }
    Write-Host "Resetting database"
    Invoke-RestMethod -Method POST -Uri "http://${ALB}/booking/api/v1/reset"

    
    # Run the experiment multiple times for each configuration to account for variability
    for ($i = 1; $i -le 1; $i++) {
        Write-Host "Starting Locust worker nodes on EC2 instances"
        # Start locust workers on EC2 instances
        $jobs = @()
        foreach ($worker in $EC2_workers) {
            $job = Start-Job -ScriptBlock {
                param($worker_ip, $key_path, $host_name, $EC2)
                $cmd = "~/.local/bin/locust -f locustfile.py --host=http://$host_name --worker --master-host=$EC2"
                ssh -i $key_path -o StrictHostKeyChecking=no ec2-user@$worker_ip $cmd
            } -ArgumentList $EC2_workers[0], $key_path, $host_name, $EC2

            Start-Sleep -Seconds 5
            Receive-Job $job
            $jobs += $job
        }
        #Write-Host "Started job, total jobs: $($jobs.Count)"
        Start-Sleep -Seconds 5 # Wait a bit to ensure workers are connected before starting the master
        Get-Job | Receive-Job
        Write-Host "Running experiment for configuration: $configuration, run: $i"
        # Run the experiment and collect results, then reset the system for the next run
        ssh -i $key_path -o StrictHostKeyChecking=no ec2-user@${EC2} "pkill -f locust; sleep 2" # Ensure any previous locust processes are killed before starting a new run
        ssh -i $key_path -o StrictHostKeyChecking=no ec2-user@${EC2} "~/.local/bin/locust -f locustfile.py --host=http://${ALB} --headless --master --csv=results_${configuration}_run${i} --expect-workers=4"
        scp -i $key_path -o StrictHostKeyChecking=no ec2-user@${EC2}:~/results_${configuration}_run${i}* ./results/
        Write-Host "Resetting system for next run"

        $jobs | Stop-Job
        $jobs | Remove-Job
        
        # Clear queue
        aws ecs update-service --cluster $queue_cluster_name --service $queue_service_name --force-new-deployment | Out-Null # Force redeploy queue service to clear any queued requests
         if ($LASTEXITCODE -ne 0) {
            Stop-Experiment -jobs $jobs -message "Failed to update queue service for configuration: $configuration, run: $i. Stopping experiment."
        }
         aws ecs wait services-stable --cluster $queue_cluster_name --services $queue_service_name | Out-Null
         if ($LASTEXITCODE -ne 0) {
            Stop-Experiment -jobs $jobs -message "Failed to reach stable state for queue service during reset for configuration: $configuration, run: $i. Stopping experiment."
        }
        
        # Scale booking service down to minimum state
        aws ecs update-service --cluster $cluster_name --service $service_name --desired-count $min_tasks | Out-Null # Scale down to minimum to reset state
        if ($LASTEXITCODE -ne 0) {
            Stop-Experiment -jobs $jobs -message "Failed to update service for configuration: $configuration, run: $i. Stopping experiment."
        }
        aws ecs wait services-stable --cluster $cluster_name --services $service_name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Stop-Experiment -jobs $jobs -message "Failed to reach stable state for configuration: $configuration, run: $i. Stopping experiment."
        }
        
        # Clear database
        Invoke-RestMethod -Method POST -Uri "http://${ALB}/booking/api/v1/reset"
    }
}


aws ec2 stop-instances --instance-ids $instance_ids | Out-Null

