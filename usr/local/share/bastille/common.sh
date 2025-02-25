#!/bin/sh
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2018-2025, Christer Edwards <christer.edwards@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Source config file
. /usr/local/etc/bastille/bastille.conf

COLOR_RED=
COLOR_GREEN=
COLOR_YELLOW=
COLOR_RESET=

bastille_root_check() {
    if [ "$(id -u)" -ne 0 ]; then
        ## permission denied
        error_notify "Bastille: Permission Denied"
        error_exit "root / sudo / doas required"
    fi
}

enable_color() {
    . /usr/local/share/bastille/colors.pre.sh
}

# If "NO_COLOR" environment variable is present, or we aren't speaking to a
# tty, disable output colors.
if [ -z "${NO_COLOR}" ] && [ -t 1 ]; then
    enable_color
fi

# Error/Info functions
error_notify() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}" 1>&2
}

error_continue() {
    error_notify "$@"
    # Disabling this shellcheck as we only ever call it inside of a loop
    # shellcheck disable=SC2104
    continue
}

# Notify message on error and exit
error_exit() {
    error_notify "$@"
    exit 1
}

info() {
    echo -e "${COLOR_GREEN}$*${COLOR_RESET}"
}

warn() {
    echo -e "${COLOR_YELLOW}$*${COLOR_RESET}"
}

check_target_exists() {
    local _TARGET="${1}"
    if [ ! -d "${bastille_jailsdir}"/"${_TARGET}" ]; then
        return 1
    else
        return 0
    fi
}

check_target_is_running() {
    local _TARGET="${1}"
    if [ ! "$(/usr/sbin/jls name | awk "/^${_TARGET}$/")" ]; then
        return 1
    else
        return 0
    fi
}

check_target_is_stopped() {
    local _TARGET="${1}"
    if [ "$(/usr/sbin/jls name | awk "/^${_TARGET}$/")" ]; then
        return 1
    else
        return 0
    fi
}

generate_static_mac() {
    local jail_name="${1}"
    local external_interface="${2}"
    local external_interface_mac="$(ifconfig ${external_interface} | grep ether | awk '{print $2}')"
    # Use the FreeBSD vendor MAC prefix for jail MAC prefix "58:9c:fc"
    local macaddr_prefix="58:9c:fc"
    # Hash interface+jailname for jail MAC suffix
    local macaddr_suffix="$(echo -n "${external_interface_mac}${jail_name}" | sed 's#:##g' | sha256 | cut -b -5 | sed 's/\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F]\)/\1:\2:\3/')"
    if [ -z "${macaddr_prefix}" ] || [ -z "${macaddr_suffix}" ]; then
        error_notify "Failed to generate MAC address."
    fi
    macaddr="${macaddr_prefix}:${macaddr_suffix}"
    export macaddr
}

generate_vnet_jail_netblock() {
    local jail_name="${1}"
    local use_unique_bridge="${2}"
    local external_interface="${3}"
    local static_mac="${4}"
    ## determine number of interfaces + 1
    ## iterate num and grep all jail configs
    ## define uniq_epair
    local _epair_if_count="$(grep -Eos 'epair[0-9]+' ${bastille_jailsdir}/*/jail.conf | sort -u | wc -l | awk '{print $1}')"
    local _bastille_if_count="$(grep -Eos 'bastille[0-9]+' ${bastille_jailsdir}/*/jail.conf | sort -u | wc -l | awk '{print $1}')"
    local epair_num_range=$((_epair_if_count + 1))
    local bastille_num_range=$((_bastille_if_count + 1))
    if [ -n "${use_unique_bridge}" ]; then
        if [ "${_epair_if_count}" -gt 0 ]; then  
            for _num in $(seq 0 "${epair_num_range}"); do
                if ! grep -Eosq "epair${_num}" ${bastille_jailsdir}/*/jail.conf; then
                    local uniq_epair_bridge="${_num}"
                    break
                fi
            done
        else
            local uniq_epair_bridge="0"
        fi
    else
        if [ "${_bastille_if_count}" -gt 0 ]; then  
            for _num in $(seq 0 "${bastille_num_range}"); do
                if ! grep -Eosq "bastille${_num}" ${bastille_jailsdir}/*/jail.conf; then
                    local uniq_epair="bastille${_num}"
                    break
                fi
            done
        else
            local uniq_epair="bastille0"
        fi
    fi
    ## If BRIDGE is enabled, generate bridge config, else generate VNET config
    if [ -n "${use_unique_bridge}" ]; then
        if [ -n "${static_mac}" ]; then
            ## Generate bridged VNET config with static MAC address
            generate_static_mac "${jail_name}" "${external_interface}"
            cat <<-EOF
  vnet;
  vnet.interface = epair${uniq_epair_bridge}b;
  exec.prestart += "ifconfig epair${uniq_epair_bridge} create";
  exec.prestart += "ifconfig ${external_interface} addm epair${uniq_epair_bridge}a";
  exec.prestart += "ifconfig epair${uniq_epair_bridge}a ether ${macaddr}a";
  exec.prestart += "ifconfig epair${uniq_epair_bridge}b ether ${macaddr}b";
  exec.prestart += "ifconfig epair${uniq_epair_bridge}a description \"vnet host interface for Bastille jail ${jail_name}\"";
  exec.poststop += "ifconfig ${external_interface} deletem epair${uniq_epair_bridge}a";
  exec.poststop += "ifconfig epair${uniq_epair_bridge}a destroy";
EOF
        else
            ## Generate bridged VNET config without static MAC address
            cat <<-EOF
  vnet;
  vnet.interface = epair${uniq_epair_bridge}b;
  exec.prestart += "ifconfig epair${uniq_epair_bridge} create";
  exec.prestart += "ifconfig ${external_interface} addm epair${uniq_epair_bridge}a";
  exec.prestart += "ifconfig epair${uniq_epair_bridge}a description \"vnet host interface for Bastille jail ${jail_name}\"";
  exec.poststop += "ifconfig ${external_interface} deletem epair${uniq_epair_bridge}a";
  exec.poststop += "ifconfig epair${uniq_epair_bridge}a destroy";
EOF
        fi
    else
        if [ -n "${static_mac}" ]; then
            ## Generate VNET config with static MAC address
            generate_static_mac "${jail_name}" "${external_interface}"
            cat <<-EOF
  vnet;
  vnet.interface = e0b_${uniq_epair};
  exec.prestart += "jib addm ${uniq_epair} ${external_interface}";
  exec.prestart += "ifconfig e0a_${uniq_epair} ether ${macaddr}a";
  exec.prestart += "ifconfig e0b_${uniq_epair} ether ${macaddr}b";
  exec.prestart += "ifconfig e0a_${uniq_epair} description \"vnet host interface for Bastille jail ${jail_name}\"";
  exec.poststop += "jib destroy ${uniq_epair}";
EOF
        else
            ## Generate VNET config without static MAC address
            cat <<-EOF
  vnet;
  vnet.interface = e0b_${uniq_epair};
  exec.prestart += "jib addm ${uniq_epair} ${external_interface}";
  exec.prestart += "ifconfig e0a_${uniq_epair} description \"vnet host interface for Bastille jail ${jail_name}\"";
  exec.poststop += "jib destroy ${uniq_epair}";
EOF
        fi
    fi
}

set_target() {
    local _TARGET="${1}"
    if [ "${_TARGET}" = ALL ] || [ "${_TARGET}" = all ]; then
        target_all_jails
    else
        check_target_exists "${_TARGET}" || error_exit "Jail not found \"${_TARGET}\""
        JAILS="${_TARGET}"
        TARGET="${_TARGET}"
        export JAILS
        export TARGET
    fi
}

set_target_single() {
    local _TARGET="${1}"
    if [ "${_TARGET}" = ALL ] || [ "${_TARGET}" = all ]; then
        error_exit "[all|ALL] not supported with this command."
    elif [ "$(echo ${_TARGET} | wc -w)" -gt 1 ]; then
        error_exit "Error: Command only supports a single TARGET."
    elif echo "${_TARGET}" | grep -Eq '^[0-9]+$'; then
        if get_jail_name "${_TARGET}" > /dev/null; then
            _TARGET="$(get_jail_name ${_TARGET})"
        else
            error_exit "Error: JID \"${_TARGET}\" not found. Is jail running?"
        fi
    elif
        ! check_target_exists "${_TARGET}"; then
            if jail_autocomplete "${_TARGET}" > /dev/null; then
                _TARGET="$(jail_autocomplete ${_TARGET})"
            elif [ $? -eq 2 ]; then
                error_exit "Jail not found \"${_TARGET}\""
            else
                exit 1
            fi
    fi
    TARGET="${_TARGET}"
    JAILS="${_TARGET}"
    export TARGET
    export JAILS
}

target_all_jails() {
    local _JAILS="$(bastille list jails)"
    JAILS=""
    for _jail in ${_JAILS}; do
        if [ -d "${bastille_jailsdir}/${_jail}" ]; then
            JAILS="${JAILS} ${_jail}"
        fi
    done
    export JAILS
}

checkyesno() {
    ## copied from /etc/rc.subr -- cedwards (20231125)
    ## issue #368 (lowercase values should be parsed)
    ## now used for all bastille_zfs_enable=YES|NO tests
    ## example: if checkyesno bastille_zfs_enable; then ...
    ## returns 0 for enabled; returns 1 for disabled
    eval _value=\$${1}
    case $_value in
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1)
        return 0
        ;;
    [Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0)
        return 1
        ;;
    *)
        warn "\$${1} is not set properly - see rc.conf(5)."
        return 1
        ;;
    esac
}

