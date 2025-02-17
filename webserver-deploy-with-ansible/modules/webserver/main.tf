
data "terraform_remote_state" "vpc" {
  backend   = "s3"

  config = {
    bucket         = "dpt4-terraform-state"
    key            = "dpt4/vpc/terraform.tfstate"
    region         = "us-east-1"
  }
}

data "aws_ami" "dpt_ami" {
  most_recent = true
  owners      = ["135159588584"]

  filter {
    name   = "name"
    values = ["dpt-*"]
  }
}

data "template_cloudinit_config" "init" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = "${file("modules/webserver/scripts/installhttpd.sh")}"
 }

}


resource "aws_launch_configuration" "dpt_lc" {
  name_prefix   = "${var.application}-lc-"
  image_id             = data.aws_ami.dpt_ami.id
  key_name     = var.keypair
  security_groups      = [aws_security_group.dpt_sg.id]
  user_data_base64     = data.template_cloudinit_config.init.rendered
  enable_monitoring    = var.enable_monitor
  ebs_optimized        = var.enable_ebs_optimization
  instance_type        = var.instance_type
  iam_instance_profile = var.instance_profile

  root_block_device {
    volume_type           = var.root_ebs_type
    volume_size           = var.root_ebs_size
    delete_on_termination = var.root_ebs_del_on_term
    
  }

  associate_public_ip_address = var.associate_public_ip_address
  
}

resource "aws_autoscaling_group" "dpt_asg" {
  name                      = "${var.application}-dpt-asg"
  max_size                  = var.asg_max_cap
  min_size                  = var.asg_min_cap
  desired_capacity          = var.asg_desired_cap
  health_check_grace_period = var.asg_health_check_grace_period
  health_check_type         = var.asg_health_check_type
  force_delete              = var.asg_force_delete
  termination_policies      = var.asg_termination_policies
  suspended_processes       = var.asg_suspended_processes
  launch_configuration      = aws_launch_configuration.dpt_lc.name
  vpc_zone_identifier       = [data.terraform_remote_state.vpc.outputs.priv_subnet]
  default_cooldown          = var.asg_default_cooldown
  enabled_metrics           = var.asg_enabled_metrics
  metrics_granularity       = var.asg_metrics_granularity
  protect_from_scale_in     = var.asg_protect_from_scale_in
  target_group_arns         = ["${aws_lb_target_group.webtg1.arn}"]
  
  tag {
    key                 = "application"
    value               = "${var.application}-dpt"
    propagate_at_launch = true
  }
}

resource "aws_cloudwatch_metric_alarm" "dpt-cpu-alarm" {
  alarm_name          = "dpt-${var.application}-cpu-alarm"
  alarm_description   = "dpt-${var.application}-cpu-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"

  dimensions = {
    "AutoScalingGroupapplication" = aws_autoscaling_group.dpt_asg.name
  }

  actions_enabled = true
  alarm_actions   =  ["${var.notifications_arn}"]
  ok_actions      =  ["${var.notifications_arn}"]
}

# Create notifications for the ASG
resource "aws_autoscaling_notification" "notifications" {
  group_names = [
    aws_autoscaling_group.dpt_asg.name,
  ]

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
  ]

  topic_arn = var.notifications_arn
}

# Create Security Group for  dpt
resource "aws_security_group" "dpt_sg" {
  name        = "${var.application}-dpt-security-group"
  description = "Allow dpt traffic"
  vpc_id      = data.terraform_remote_state.vpc.outputs.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_metric_alarm" "target-healthy-count" {
  alarm_name          = "${var.application}-dpt-tg1-Healthy-Count"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "0"

  dimensions = {
    LoadBalancer = "${aws_lb.dpt.arn_suffix}"
    TargetGroup  = "${aws_lb_target_group.webtg1.arn_suffix}"
  }

  alarm_description  = "Trigger an alert when ${var.application}-tg1  has 1 or more unhealthy hosts"
  alarm_actions      = ["${var.notifications_arn}"]
  ok_actions         = ["${var.notifications_arn}"]
}

resource "aws_security_group" "elb" {
  name        = "${var.application}-alb-sg"
  description = "ALB SG"

  vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id

  # HTTP access from anywhere
   ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  } 

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}


resource "aws_lb" "dpt" {
  name               = "${var.application}-dpt"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.elb.id}"]
  subnets            =   [data.terraform_remote_state.vpc.outputs.pub_subnet1,data.terraform_remote_state.vpc.outputs.pub_subnet2]

 tags = {
      application         = "${var.application}-dpt"
  }
}

resource "aws_lb_listener" "web_tg1" {
  load_balancer_arn = "${aws_lb.dpt.arn}"
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.webtg1.arn}"
  }
}


resource "aws_lb_target_group" "webtg1" {
  name     = "${var.application}-tg1"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.terraform_remote_state.vpc.outputs.vpc_id

health_check {
                path = "/index.html"
                port = "80"
                protocol = "HTTP"
                healthy_threshold = 2
                unhealthy_threshold = 2
                interval = 5
                timeout = 4
                matcher = "200-308"
        }
}


resource "aws_route53_record" "dpt" {
  zone_id = "Z06693023THGYYPBRN6UK"
  name    = "${var.dns_name}"
  type    = "A"

  alias {
    name                   = "${aws_lb.dpt.dns_name}"
    zone_id                = "${aws_lb.dpt.zone_id}"
    evaluate_target_health = true
  }
}


