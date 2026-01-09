pm_api_url            = "https://192.168.20.10:8006/api2/json"
pm_api_token_id       = "root@pam!terraform"
pm_api_token_secret   = "a596e45d-c40c-42ce-8127-70b5e78eb3b9"
pm_tls_insecure       = true

pm_node        = "server"
template_name  = "debian-13-cloudinit"
template_vmid  = 9001
storage        = "local-lvm"
bridge         = "vmbr0"
gateway        = "192.168.20.1"
nameserver     = "1.1.1.1"
searchdomain   = "home.lab"
cloud_init_user = "deployer"

ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhLzivPgJGOMkfj6Fg8WBbPvJIMLQHjpFTnXZVsncBg prakash2ji@gmail.com",
]

