# Manual downloads for the SIEM bundle

Files that can't be downloaded by script go here before running `bundle/build-bundle.sh`:

- `iDRAC-SMIv2.mib`: from the iDRAC9 "SNMP MIB" download on dell.com (drivers & downloads for the
  server model). It is used by snmptrapd and by the snmp_exporter generator.

Everything else in this folder is ignored by git.
