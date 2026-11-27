# What happens in the minute AFTER this machine runs out of memory.
#
# An agent session is a browser, a language server and a compiler, and somebody
# runs several at once. So the number that matters is not how much memory the
# box has, it is what it does when that runs out, and the default answer is the
# worst one available.
#
# With no swap the kernel has nowhere to put a cold anonymous page, so the only
# memory it can reclaim is file backed: it evicts a program's own text pages and
# faults them straight back in to run the code that asked for memory. The
# machine live-locks in direct reclaim, and the part that matters is that sshd
# cannot get a page to accept a connection. It answers ping and refuses logins,
# for minutes, until the kernel OOM killer eventually picks something by
# resident size, which may be the thing somebody was talking to.
#
# Turning swap OFF does not avoid that, it chooses it. Chris Down's "In defence
# of swap" is the long version and this is the whole of it: no swap does not
# remove the thrashing, it moves the thrashing from anonymous pages onto file
# pages, where it is worse because those pages are the executables.
#
# So: somewhere to put cold pages, and something that kills early enough that
# the live-lock never starts. Two mechanisms, and deliberately not a third.
{ ... }:
{
  # Compressed swap in RAM, which is what "a little swap" means now. Fedora has
  # shipped exactly this by default since Fedora 33 and sizes it the way the
  # NixOS module does, half of RAM. zstd gets roughly threefold on a heap, so
  # the memory held back comes back larger than it left.
  #
  # Deliberately NOT a partition or a file on the disk. This machine's disk is
  # the one the agents are writing builds to, and swapping onto it under
  # pressure turns a live-lock that resolves in seconds into one that resolves
  # in ten minutes. A machine that is unreachable for ten minutes is down.
  #
  # Note for anyone reaching for a swap FILE later: root is btrfs, which is
  # copy-on-write, so a swap file needs `chattr +C` on a fresh empty file before
  # anything is written to it, and it cannot live on a subvolume that gets
  # snapshotted. `swapon` refuses one that does not meet that with "swapfile has
  # holes". zram avoids the whole question, which is the other reason it is here.
  zramSwap.enable = true;

  # And the killer, which stops being optional once swap is zram.
  #
  # zram is a block device whose capacity is IN RAM, so filling it frees
  # nothing, and the kernel's own OOM killer can fail to fire in time against
  # it: the machine locks up rather than losing a process. This is why the NixOS
  # wiki's own swap page says a userspace OOM killer is highly recommended
  # alongside zram rather than listing it as an option.
  #
  # earlyoom rather than systemd-oomd, which is the less fashionable choice.
  # oomd decides from pressure stall information about a cgroup, and that is the
  # better signal when the thing under pressure is a service that somebody
  # arranged into a cgroup on purpose. Here it is a person's browser, sitting in
  # whatever session it was started from, and oomd's issue tracker is largely
  # people reporting that it fired too late or took the entire session with it
  # when killing one process would have done.
  #
  # earlyoom checks available memory and swap up to ten times a second and
  # selects a process by kernel OOM score, adjusted by the preferences below.
  # This is an emergency fallback, not a guarantee that access survives.
  services.earlyoom = {
    enable = true;
    # Thresholds left at the module's defaults on purpose. They are 10% free
    # memory and 10% free swap, both of which have to be under before anything
    # is killed, and they are the numbers earlyoom has shipped and been tuned
    # against for years. A number invented here would be a number nobody has
    # ever watched behave.

    # Which is not to say the CHOICE of victim should be left alone. These
    # adjust OOM scores; they do not make an avoided process immune.
    #
    # Browsers only in the prefer list, deliberately. They are the class that
    # goes runaway on a machine like this and the class that costs nothing to
    # lose: a browser is restartable and a person watches it happen. The
    # tempting additions are `node` and a language server, and both are wrong
    # for the same reason, which is that on this machine they are as likely to
    # BE the agent session as to be the thing breaking it. Their OOM scores
    # still make them eligible when memory is exhausted.
    extraArgs = [
      "--prefer"
      "^(chrome|chromium|firefox|electron)$"
      "--avoid"
      "^(systemd|sshd|sshd-session|sshd-auth|dbus-daemon|herdr|tailscaled)$"
    ];
  };
}
