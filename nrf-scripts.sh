if [[ "$(uname -a | cut -f3 -d' ')" =~ .*-microsoft-.* ]]; then 
    IS_WSL=1
else
    IS_WSL=0
fi

if [ -e ${HOME}/.nrfconfig ]; then
    cat ${HOME}/.nrfconfig
    source ${HOME}/.nrfconfig
fi

function open_serial_port {
    local TERMAPP

    if [ ${IS_WSL} -eq 1 ]; then
        TERMAPP="plink.exe -sercfg ${1},8,n,1,N -serial ${2}"
    else
        TERMAPP="picocom --omap delbs -b ${1} ${2}"
    fi

    ${TERMAPP}

    while [ $? -ne 0 ]; do
        sleep 1
        ${TERMAPP}
    done
}

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
    local part=$(read_device_part $1)
    local variant=$(read_device_variant $1 | cut -c7-8 | xxd -p -r)
    local device_type="nrf${part}_xxA${variant}"
    echo ${device_type}
}

# Find JLINK tty by its serial number.
function find_device_tty {
    local ttys=$(ls /dev/ttyACM?)
    local sn

    for tty in $ttys; do
        sn=$(udevadm info --query=property --name ${tty} | \
             awk 'BEGIN {FS="="} $1 == "ID_SERIAL_SHORT" {print($2)}')

        # Remove the trailing zeros
        sn_nozero=$(echo $sn | sed 's/^0*//')
        if [ $sn_nozero == $1 ]; then
            echo ${tty}
            return
        fi
    done
}

# Query Windows registry and remove CR characters.
function reg_q()
{
    reg.exe query $* | tr -d '\r'
}

# Extract registry value from a result of "req_q [key] /s" query.
function req_q_get_value()
{
    echo "$1" | awk "\$1 == \"$2\" { print \$3 }" | head -n1
}

# Find JLINK COM port by its serial number.
function find_device_com {
    local ROOT='HKLM\SYSTEM\CurrentControlSet\Enum\USB'
    local VID="1366"
    local SEGGER_ENTRIES=$(reg_q $ROOT | grep VID_${VID})

    for ENTRY in ${SEGGER_ENTRIES}; do
        for SUB_ENTRY in $(reg_q "${ENTRY}"); do
            SUB_ENTRY_VALUE=$(reg_q "${SUB_ENTRY}" /s)
            SERVICE=$(req_q_get_value "${SUB_ENTRY_VALUE}" "Service")

            if [ "${SERVICE}" == "usbccgp" ]; then
                SEGGER_ID=$(echo -n "${SUB_ENTRY}" | sed -r -n 's/^.*\\[0]+([0-9]+)$/\1/p')
                if [ "${SEGGER_ID}" == "$1" ]; then
                    SEGGER_PARENT_ID_PREFIX=$(req_q_get_value "${SUB_ENTRY_VALUE}" "ParentIdPrefix")
                fi
            elif [ "${SERVICE}" == "JLinkCDC" ]; then
                PARENT_ID_PREFIX=$(echo -n "${SUB_ENTRY}" | sed -r -n 's/.*\\([a-f0-9&]+)$/\1/p')
                if [[ "${PARENT_ID_PREFIX}" =~ ${SEGGER_PARENT_ID_PREFIX}.* ]]; then
                    echo "$(req_q_get_value "${SUB_ENTRY_VALUE}" "PortName")"
                    return
                fi
            fi
        done
    done
}

# Find JLINK port by its serial number.
function find_device_port {
    if [ ${IS_WSL} -eq 1 ]; then
        echo "$(find_device_com "${1}")"
    else
        echo "$(find_device_tty "${1}")"
    fi
}

# If there are more than one dev kit then
# display a dialog to pick one.
function pick_device {
    local ids=$(nrfjprog -i)
    local sn

    if [ $(echo -e "$ids" | wc -l) -gt 1 ]; then 
        sn=$(echo -e "$ids" | pick) 
    else
        sn=$ids
    fi
    echo ${sn}
}

function pick_hex_file {
    local hex_files=$(find -name *.hex)
    local file

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
    local hex_file

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
    local pkg_file

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
    local hex_file
    local settings_file

    if [ $# -eq 0 ]; then
        "Usage: family [application_hex] [output_hex]"
    fi
    
    local family=${1}
    
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
    local sn=$(pick_device)
    local script=$(mktemp)
    local rtt_port=$(( 19021 + $(pidof JLinkExe | wc -w) ))
    local ranges
    
    if [ -e *.ld ]; then
      ranges=$(cat *.ld | gawk 'match($0, "RAM.*ORIGIN = ([0-9a-fA-Fx]+), LENGTH = ([0-9a-fA-Fx]+)", a) {print a[1] " " a[2]}')
      echo -e "exec SetRTTSearchRanges $ranges\n" >> ${script}
    fi
    
    local device_type=$(get_jlink_device_type ${sn})
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
        local targets=$(find -type d -name armgcc)
        
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

# Usage: nrf_flash [-s segger] [-e] [-w] [hex]
function nrf_flash {
    local flash_settings=0
    local full_erase=0
    local serial_no=""
    # We need to set OPTIND to local to properly handle consecutive calls to 
    # getopts. This is because getopts uses OPTIND to track an index of the next
    # option to be parsed. If this is global then the following fails:
    #    $ foo -s bar
    #    $ foo -s bar
    # This is because in the second call OPTIND is set to 3 hence there is 
    # nothing to parse.
    local OPTIND opt

    while getopts ":s:we" opt; do
        echo ${opt} ${OPTARG}
        case ${opt} in
            s) serial_no=${OPTARG};;
            e) full_erase=1;;
            w) flash_settings=1;;
        esac
    done
    shift $((OPTIND - 1))

    if [ -n "${1}" ]; then
        hex_file="${1}"
    else
        hex_file="$(pick_hex_file)"
    fi
    
    if [ -z ${hex_file} ]; then
        echo "No hex file provided"
        return 1
    fi

    if [ -z ${serial_no} ]; then
        serial_no=$(pick_device)
    fi

    if [ ${full_erase} -eq 1 ]; then
        echo "Performing full erase"
        soc_erase ${serial_no}
    fi
    
    if [ ${flash_settings} -eq 1 ]; then
        echo "Flashing settings to ${serial_no}"
        settings_file=$(mktemp)
        family="NRF$(read_device_part ${serial_no})"
        nrf_dfu_gen_settings ${family} ${hex_file} ${settings_file}
        soc_flash ${settings_file} ${serial_no}
    fi

    (
        echo "Flashing ${hex_file} to ${serial_no}"
        soc_flash ${hex_file} ${serial_no}
        soc_reset ${serial_no}
    )
}

# Usage: nrf_erase
function nrf_erase {
    local serial_no=$(pick_device)
    soc_erase ${serial_no}
}

# Usage: nrf_cli
function nrf_cli {
    local serial_no=$(pick_device)
    local port=$(find_device_port ${serial_no})
    
    echo "Opening ${port} for device ${serial_no}"
    open_serial_port 115200 ${port}    
}

# Usage: nrf_log
function nrf_log {
    local serial_no=$(pick_device)
    local port=$(find_device_port ${serial_no})
    
    echo "Opening ${port} for device ${serial_no}"
    open_serial_port 1000000 ${port}
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
