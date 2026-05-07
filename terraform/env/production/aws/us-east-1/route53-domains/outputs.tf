output "domains" {
  description = "Per-domain hosted zone ID, name servers, and expiration date."
  value = {
    for name, mod in module.route53_domains : name => {
      hosted_zone_id  = mod.hosted_zone_id
      name_servers    = mod.name_servers
      expiration_date = mod.expiration_date
    }
  }
}
