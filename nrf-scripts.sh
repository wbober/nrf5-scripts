if [ -e ${HOME}/.nrfconfig ]; then
    cat ${HOME}/.nrfconfig
    source ${HOME}/.nrfconfig
fi

function soc_flash {
    nrfjprog -f nrf52 --program $1 --sectorerase -s $2
}

function soc_reset {
    nrfjprog -f nrf52 -r -s $1
}

function soc_erase {
    nrfjprog -f nrf52 -e -s $1
}

# Reads INFO.PART register.
# Args: serial_no
function read_device_part {
    echo $(nrfjprog -s $1 --memrd 0x10000100 | cut -f2 -d' ' | cut -c4-8)
}

# Reads INFO.VARIANT register.
# Args: serial_no
function read_device_variant {
    echo $(nrfjprog -s $1 --memrd 0x10000104 | cut -f2 -d' ')
}

# Read part type and variant and return device type which can be
# used with jlink.
# Args: serial_no
function get_jlink_device_type {
  
  part=$(read_device_part $1)
  variant=$(read_device_variant $1 | cut -c7-8 | xxd -p -r)
  
  device_type="nrf${part}_xxA${variant}"
  echo ${device_type}
}

# Find JLINK tty by its serial number.
function find_device_tty {
    ttys=$(ls /dev/ttyACM?)
    for tty in $ttys; do
        serial_no=$(udevadm info --query=property --name ${tty} | \
                    awk 'BEGIN {FS="="} $1 == "ID_SERIAL_SHORT" {print($2)}')
        if [ $serial_no -eq $1 ]; then
            echo ${tty}
        fi
    done
}

# If there are more than one dev kit then
# display a dialog to pick one.
function pick_device {
    ids=$(nrfjprog -i)
    if [ $(echo -e "$ids" | wc -l) -gt 1 ]; then 
        sn=$(echo -e "$ids" | pick) 
    else
        sn=$ids
    fi
    echo ${sn}
}

function pick_hex_file {
    hex_files=$(find -name *.hex)
    if [ $(echo -e "$hex_files" | wc -l) -gt 1 ]; then 
        file=$(echo -e "$hex_files" | pick) 
    else
        file=$hex_files
    fi
    echo ${file}
}

########################################################################
# Public API
########################################################################

function nrf_sign {
    
    if [ $# -eq 1 ]; then
        hex_file=$1
    else
        hex_file=$(pick_hex_file)
    fi
    
    if [ -z ${hex_file} ]; then
        echo "Hex file not found"
        return 1
    fi

    echo "Signing ${hex_file} using key from ${DEFAULT_KEY_FILE}"
    nrfutil pkg generate --application $hex_file \
                         --key-file=${DEFAULT_KEY_FILE} \
                         --hw-version=52 \
                         --sd-req 0x8c \
                         --application-version=2 \
                           application.zip
}

function nrf_dfu {
    if [ $# -eq 1 ]; then
        pkg_file=$1
    else
        pkg_file=$(find -name '*.zip')
    fi
      
    echo "DFU using ${pkg_file}"
    nrfutil dfu ble -f -snr ${DEFAULT_COMM_SN} \
                       -pkg ${pkg_file} \
                       -p $(find_device_tty ${DEFAULT_COMM_SN})
}

#Usage: family [application_hex] [output_hex]
function nrf_dfu_gen_settings {
    
    if [ $# -eq 0 ]; then
        "Usage: family [application_hex] [output_hex]"
    fi
    
    family=${1}
    
    if [ -n "${2}" ]; then
        hex_file=$2
    else
        hex_file=$(pick_hex_file)
    fi
    
    if [ -z "${hex_file}" ]; then
        echo "Hex file not found"
        return 1
    fi
    
    if [ -n "${3}" ]; then
        settings_file="${3}"
    else
        settings_file="settings.hex"
    fi
    
    echo "Writing settings for ${hex_file} to ${settings_file}"
    
    nrfutil settings generate --family ${family} \
                              --application ${hex_file} \
                              --application-version 1 \
                              --bootloader-version 1 \
                              --bl-settings-version 1 \
                                ${settings_file}
}


# Attach RTT to a device.
function nrf_rtt {
    sn=$(pick_device)
    script=$(mktemp)
    rtt_port=$(( 19021 + $(pidof JLinkExe | wc -w) ))
    
    if [ -e *.ld ]; then
      ranges=$(cat *.ld | gawk 'match($0, "RAM.*ORIGIN = ([0-9a-fA-Fx]+), LENGTH = ([0-9a-fA-Fx]+)", a) {print a[1] " " a[2]}')
      echo -e "exec SetRTTSearchRanges $ranges\n" >> ${script}
    fi
    
    device_type=$(get_jlink_device_type ${sn})
    echo ${device_type}
    
    nohup JLinkExe -device ${device_type} \
                   -SelectEmuBySN ${sn} \
                   -if swd \
                   -speed auto \
                   -AutoConnect 1 \
                   -RTTTelnetPort ${rtt_port} \
                   -CommanderScript ${script} &
                   
    PID=$!

    (
        # Prevent CTRL-C from stopping the function
        trap : INT
        # Give JLinkExe a bit of time to prevent 'Connection refused' error
        sleep 1
        telnet 127.0.0.1 ${rtt_port}
    )
    
    kill ${PID}
}

# Build binary for the default board.
function nrf_make {
    (
        targets=$(find -type d -name armgcc)
        
        if [ $(echo -e "$targets" | wc -l) -gt 1 ]; then 
            target=$(echo -e "$targets" | pick) 
        else
            target=$targets
        fi

        cd $target
        pwd
        make $*
    )
}

# Usage: nrf_flash [--with-settings] [file.hex]
function nrf_flash {
    serial_no=$(pick_device)

    if [ "${1}" == "--with-settings" ]; then
        echo "Flashing settings"
        FLASH_SETTINGS=1
        shift
    else
        FLASH_SETTINGS=0
    fi
    
    if [ -n "${1}" ]; then
        hex_file="${1}"
    else
        hex_file="$(pick_hex_file)"
    fi
    
    if [ -z ${hex_file} ]; then
        echo "Hex file not found"
        return 1
    fi
    
    echo "${hex_file}"
    
    if [ ${FLASH_SETTINGS} -eq 1 ]; then
        settings_file=$(mktemp)
        family="NRF$(read_device_part ${serial_no})"
        nrf_dfu_gen_settings ${family} ${hex_file} ${settings_file}
        soc_flash ${settings_file} ${serial_no}
    fi

    (
        soc_flash ${hex_file} ${serial_no}
        soc_reset ${serial_no}
    )
}

# Usage: nrf_erase
function nrf_erase {
  serial_no=$(pick_device)
  soc_erase ${serial_no}
}

# Usage: nrf_cli
function nrf_cli {
    serial_no=$(pick_device)
    port=$(find_device_tty ${serial_no})
    
    echo "Opening ${port} for device ${serial_no}"
    
    picocom --omap delbs -b 115200 ${port}
    while [ $? -ne 0 ]; do
        sleep 1
        picocom --omap delbs -b 115200 ${port}
    done
}

########################################################################
# Bluetooth helpers
########################################################################

function bt_lescan
{
  sudo hcitool lescan
}

# Convert Bluetooth Device Address to IPv6 Link Local Address
function bt_bda_to_ll 
{
    echo $1 | awk '{split(tolower($1), octets, ":", seps); printf "fe80::%02x%s:%sff:fe%s:%s%s", xor(strtonum("0x" octets[1]), 2), octets[2], octets[3], octets[4], octets[5], octets[6]}'
}

# List unique Bluetooth LE devices.
function bt_le_list
{
  # Change buffering to output every line
  # Run command for 1s and then send SIGINT
  # Do lescan
  # Reject duplicates and devices without a name
  sudo stdbuf -oL timeout -s SIGINT 1s hcitool lescan | awk '!seen[$0] && $2 != "(unknown)" && $0 != "LE Scan ..." { print $0 } {++seen[$0]}'
}

# Find an address of a BLE device by its name.
function bt_bda_find
{
  printf "$(bt_le_list)\n" | awk -v name="$1" '$2 ~ name { print $1 }'
}

# Connect to IPSP enabled BLE device.
# Usage: [--name <device name>] | [--addr <device addr>]
#
# If device name or addr is not specified the command will scan for
# LE devices and show a list which allows for selecting the device to 
# connec to.
#
function bt_ipsp_connect
{
  if [ $# -eq 1 ]; then
    addr=$(bt_le_list | pick | cut -f1 -d" ")
    addr_type=$1
  elif [ $# -eq 2 ]; then
    if [ $1 == '--name' ]; then
      addr=$(bt_bda_find "$2")
    elif [ $1 == '--addr' ]; then
      addr=$2
    fi
    addr_type=$3
  fi

  if [ -n "$addr" ]; then
    echo "Connecting to $addr $(bt_bda_to_ll $addr)"
    sudo su -c "echo \"connect ${addr} ${addr_type}\" > /sys/kernel/debug/bluetooth/6lowpan_control"
  else
    echo "Device not found"
  fi
}

function bt_hci_attach
{
  if [ -n "${1}" ]; then
    device_sn="${1}"
  else
    device_sn="$(pick_device)"
  fi
    
  pid=$(pidof btattach)
  if [ -n "${pid}" ]; then
    sudo kill ${pid}
  fi

  port=$(find_device_tty ${device_sn})
  
  if [ -n "$port" ]; then
    echo "Attaching to: $port"
    sudo btattach -B $port -S 1000000 -P h4 &>/dev/null &
    sleep 1
    sudo btmgmt static-addr FF:02:03:04:05:FF
    sudo btmgmt auto-power
  else
    echo "Device not found"
  fi
}
