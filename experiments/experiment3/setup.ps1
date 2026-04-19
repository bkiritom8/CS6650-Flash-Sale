Get-Content .env | ForEach-Object {
    $key, $value = $_ -split '=', 2
    Set-Variable -Name $key -Value $value
}
# $key_path = "" #path to your SSH key for EC2 access
Write-Host "Creating security group for Locust workers"
$vpc_id = aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text
$my_ip = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
$sg_id = aws ec2 describe-security-groups --filters "Name=group-name,Values=locust-sg" --query "SecurityGroups[0].GroupId" --output text

if ($sg_id -eq "None") {
    $sg_id = aws ec2 create-security-group --group-name "locust-sg" --description "Security group for Locust EC2 instances" --vpc-id $vpc_id --query "GroupId" --output text
    aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 22 --cidr "${my_ip}/32"
    aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 5557 --source-group $sg_id
    aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 5558 --source-group $sg_id
}
Write-Host "Security group ID for Locust workers: $sg_id"

Write-Host "Launching EC2 instances for Locust workers"
$ami_id = aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text
aws ec2 run-instances --image-id $ami_id --count 5 --instance-type t2.micro --key-name "cs6650key1" --tag-specifications 'ResourceType=instance,Tags=[{Key=Role,Value=locust-worker}]' --security-group-ids $sg_id | Out-Null
Start-Sleep -Seconds 30 # wait for instances to initialize
$instance_ids = (aws ec2 describe-instances --filters "Name=tag:Role,Values=locust-worker" "Name=instance-state-name,Values=stopped,running" --query "Reservations[*].Instances[*].InstanceId" --output text).Split()
$EC2_ips = (aws ec2 describe-instances --instance-ids $instance_ids --query "Reservations[*].Instances[*].PublicIpAddress" --output text).Split()
aws ec2 wait instance-status-ok --instance-ids $instance_ids

$jobs = @()
foreach ($instance in $EC2_ips) {
     Write-Host "Copying test script to instance $instance"
     # SSH into the instance and set up Locust
    $job = Start-Job -ScriptBlock {
        param($key_path, $instance)
        $cmd = "
        sudo yum update -y
        sudo yum install -y python3 python3-pip
        pip3 install locust 'urllib3<2.0' --user
        "
        ssh -i $key_path -o StrictHostKeyChecking=no ec2-user@$instance $cmd
    } -ArgumentList ($key_path, $instance)
    $jobs += $job
}
Write-Host "Waiting for EC2 instances to be set up with Locust..."
$jobs | Wait-Job
Write-Host "EC2 instances are ready. Uploading locustfile.py to each instance..."
foreach ($instance in $EC2_ips) {
     scp -i $key_path -o StrictHostKeyChecking=no locustfile.py ec2-user@${instance}:~/locustfile.py
}
Write-Host "Finished setting up EC2 instances and Locust workers"
aws ec2 describe-instances --filters "Name=tag:Role,Values=locust-worker" "Name=instance-state-name,Values=stopped,running" --query "Reservations[*].Instances[*].InstanceId" --output text