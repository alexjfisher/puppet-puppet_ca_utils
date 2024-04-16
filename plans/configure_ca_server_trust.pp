# @summary Configures two CA servers for mutual trust
#
# @param targets
#   The CA server targets that should be configured for mutual trust
#   relationships. Generally speaking, this should simply be the list of
#   Puppet CA servers that mutual trust should be established between.
# @param ca_hosts
#   The CA systems to gather trust information from. By default, this will
#   be the same as the set of targets. Sometimes it may be desirable to gather
#   trust data from multiple systems but only configure that trust on a
#   subset. This parameter enables that atypical use case.
# @param crl_bundle
#   How to build the CRL bundle. When set to 'full', the plan will run a task
#   on each ca_hosts target to collect the full CRL information. When set to
#   'api', the data gathered will be limited to data available from the Puppet
#   CA REST API.
# @param restart_puppetserver
#   Whether or not to restart Puppet Server after reconfiguring it. Defaults
#   to false. Do not set this to true if using the orchestrator as the Bolt
#   transport.
#
plan puppet_ca_utils::configure_ca_server_trust (
  TargetSpec     $targets,
  TargetSpec     $ca_hosts             = $targets,
  Enum[full,api] $crl_bundle           = 'full',
  Boolean        $restart_puppetserver = false,
) {
  $update_targets = get_targets($targets)
  $ca_targets  = get_targets($ca_hosts)

  $api_ca_data = run_task('puppet_ca_utils::api_ca_data', 'localhost',
    ca_hostnames => $ca_targets.map |$t| { $t.name },
  )[0]

  if ($crl_bundle == 'full') {
    $full_crl_bundle = run_task('puppet_ca_utils::get_ca_crl', $ca_targets).map |$r| {
      $r['ca_crl']
    }.puppet_ca_utils::merge_crl_bundles()
  }
  else { # $crl_bundle == 'api'
    $full_crl_bundle = $api_ca_data['crl_bundle']
  }

  $ordered_pem_bundles = {
    'ca_crt'    => puppet_ca_utils::ordered_ca_bundles($api_ca_data['peer_certs'], $api_ca_data['ca_bundle']),
    'ca_crl'    => puppet_ca_utils::ordered_crl_bundles($api_ca_data['peer_certs'], $full_crl_bundle),
    'infra_crl' => puppet_ca_utils::ordered_crl_bundles($api_ca_data['peer_certs'], $api_ca_data['crl_bundle']),
  }

  # We will use the 'name' var in the apply block below
  $update_targets.each |$target| {
    $target.set_var('hostname', $target.name)
  }

  # Note that there is a race condition here around the CRL.
  # See https://tickets.puppetlabs.com/browse/SERVER-2550
  apply($update_targets) {
    File {
      ensure => file,
      owner  => 'pe-puppet',
      group  => 'pe-puppet',
      notify => $restart_puppetserver ? {
        true  => Service['pe-puppetserver'],
        false => undef,
      },
    }

    file { 'copy-of-original-ca-cert':
      path    => '/etc/puppetlabs/puppet/ssl/ca/ca_crt.pem.pre-configure_ca_server_trust',
      content => '/etc/puppetlabs/puppet/ssl/ca/ca_crt.pem',
      replace => false,
    }

    file { [
      '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
      '/etc/puppetlabs/puppet/ssl/ca/ca_crt.pem',
    ]:
      content => $ordered_pem_bundles['ca_crt'][$hostname],
      require => File['copy-of-original-ca-cert'],
    }

    file { 'copy-of-original-crl':
      path    => '/etc/puppetlabs/puppet/ssl/ca/ca_crl.pem.pre-configure_ca_server_trust',
      content => '/etc/puppetlabs/puppet/ssl/ca/ca_crl.pem',
      replace => false,
    }

    file { [
      '/etc/puppetlabs/puppet/ssl/crl.pem',
      '/etc/puppetlabs/puppet/ssl/ca/ca_crl.pem',
    ]:
      content => $ordered_pem_bundles['ca_crl'][$hostname],
      require => File['copy-of-original-crl'],
    }

    file { '/etc/puppetlabs/puppet/ssl/ca/infra_crl.pem':
      content => $ordered_pem_bundles['infra_crl'][$hostname],
    }

    # Question: does Puppet Server need reloading?
    service { 'pe-puppetserver': }
  }

  # Note: agents and compilers will receive the updated CA bundle and CRL through normal
  # distribution means

  return('Complete')
}
