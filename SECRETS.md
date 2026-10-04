# Service credentials and machine delivery

Required credentials belong to service metadata in ryra-services, not a second
list in a machine template. Ryra's service setup reads that metadata and prompts
for labelled values or generates internal passwords. The organization declaration
records vault, group access and machine-scoped delivery references, not plaintext.

Templates already import the generated `modules/secrets.nix`. Keep that import
and let Ryra regenerate the module and SOPS-encrypted input at deployment. The
existing SOPS/age and sops-nix path handles encryption and runtime secret files;
no additional template secret store or hand-written per-service SOPS wiring is
needed. Service-specific file formats belong in the service's credential schema.

Machine inputs remain pinned. Updating a service registry or template requires an
explicit lock-file update and deployment; changing the upstream metadata alone
does not modify a running machine. External projects using these templates without
Ryra still need to provide their own SOPS configuration and age identities.
