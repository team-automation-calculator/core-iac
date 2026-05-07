resource "aws_route53_record" "gmail_mx" {
  zone_id = module.route53_domains["automation-calculations.net"].hosted_zone_id
  name    = "automation-calculations.net"
  type    = "MX"
  ttl     = 60
  records = ["1 SMTP.GOOGLE.COM."]
}
