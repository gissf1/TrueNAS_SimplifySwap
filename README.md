# TrueNAS SimplifySwap

## Introduction

By default, a TrueNAS Scale system uses mirrored encrypted swap space on each disk of the volume selected in the configuration.  This has been the default since at least 24.04 Dragonfish.  On older systems with low memory, the load of doing constant encryption for swap can make the system unstable and nearly unusable.  Furthermore, allowing striping (RAID0) instead of mirroring (RAID1) for swap should also significantly help swap performance, at the risk of system instability in the case of disk failure.

This implementation is a conceptually simple script that checks if the default swap configuration is active, and, if so, live-replaces it without downtime to remove encryption and instead use the kernel's default RAID0 swap capability.  This would need to be done on each startup since the startup scripts in TrueNAS Scale rebuild the swap configuration during boot if it isn't in the expected configuration.  So the solution is to simply add a startup script in TrueNAS Scale's UI to call this script on startup to correct it later in the boot process.

### Setup

The setup for this is quite simple:

1. Login to your TrueNAS Scale Web UI as an administrator
2. Click on the `System Settings` navigation link on the left
3. Click on the `Advanced` option from the submenu
4. In the section titled `Init/Shutdown Scripts`, click the `Add` button
5. The `Add Init/Shutdown Scripts` dialog pops up:
    | Entry Fields        | Description                                              |
    | ------------------- | -------------------------------------------------------- |
    | Description         | `simplify swap (unencrypt + raid0 for faster swapping)` |
    | Type                | `Command`                                                |
    | Command             | `/path/to/your/TrueNAS_SimplifySwap/simplify-swap.sh`   |
    | When                | `Post Init`                                              |
    | Enabled             | Check to enable system suspend; disable if issues arise. |
    | Timeout             | `90` You can adjust this if necessary                    |

    - **Command**:
      - The `simplify-swap.sh` script does not support any command line options, but it can be used interactively via ssh to provide some output describing what is happening and indicating if something is going wrong in the process.

      - Typically, output from CLI commands or scripts run this way are not logged, and therefore the output is lost.  You can retain the information and messages by changing the `command` field to something like the following:

        `/path/to/your/TrueNAS_SimplifySwap/simplify-swap.sh >> /root/simplify-swap.stdout 2>> /root/simplify-swap.stderr`

        This would save output into files `/root/simplify-swap.stdout` and `/root/simplify-swap.stderr` to hopefully help with debugging.

        These output files will grow on each system bootup and will never be rotated or removed without manual intervention, so when you finish debugging, make sure to restore the `command` field and delete the output files.

    - **Enabled**:
      - Check this to enable the script at startup
      - Also an easy way to disable if issues arise

6. Click the `Save` button
