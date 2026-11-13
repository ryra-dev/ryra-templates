# A machine that brings its own disk and boot loader, such as a cloud's NixOS image or a box
# installed by hand. Its settings sit in the machine's own modules, and Ryra's layout steps aside.
{ disabledModules = [ ./hardware.nix ]; }
