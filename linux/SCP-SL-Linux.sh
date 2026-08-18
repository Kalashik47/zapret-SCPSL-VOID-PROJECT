#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_VERSION="1.10.1"
readonly ZAPRET2_VERSION="${ZAPRET2_VERSION:-1.0.4}"
readonly ZAPRET2_DIR="/opt/zapret2"
readonly PROFILE_BEGIN="# BEGIN VOID PROJECT SCP-SL"
readonly PROFILE_END="# END VOID PROJECT SCP-SL"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly PROFILE_FILE="${SCRIPT_DIR}/scpsl.conf"

TEMP_DIR=""

banner() {
  printf '\n'
  printf '============================================================\n'
  printf '              СДЕЛАНО СЕРВЕРОМ VOID PROJECT                 \n'
  printf '                 193.164.16.165:7777                        \n'
  printf '          Zapret SCP:SL Linux v%s                            \n' "${PROJECT_VERSION}"
  printf '============================================================\n\n'
}

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Использование:
  ./SCP-SL-Linux.sh install         скачать zapret2, установить и применить профиль
  ./SCP-SL-Linux.sh apply           применить профиль к установленной zapret2
  ./SCP-SL-Linux.sh start           запустить zapret2
  ./SCP-SL-Linux.sh stop            остановить zapret2
  ./SCP-SL-Linux.sh restart         перезапустить zapret2
  ./SCP-SL-Linux.sh status          показать состояние и активные настройки
  ./SCP-SL-Linux.sh test            проверить центральные сервисы SCP:SL
  ./SCP-SL-Linux.sh remove-profile  удалить только блок VOID PROJECT из config

Команды install/apply/start/stop/restart/remove-profile выполняются через sudo.
EOF
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "не найдена команда '$1'. Установите её пакетным менеджером."
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "эта команда требует root. Запустите: sudo $0 $1"
}

cleanup() {
  if [[ -n "${TEMP_DIR}" ]]; then
    case "${TEMP_DIR}" in
      /tmp/void-scpsl.*|/var/tmp/void-scpsl.*) rm -rf -- "${TEMP_DIR}" ;;
    esac
  fi
}

trap cleanup EXIT

detect_firewall() {
  if command -v nft >/dev/null 2>&1; then
    printf 'nftables\n'
  elif command -v iptables >/dev/null 2>&1; then
    printf 'iptables\n'
  else
    die "не найдены nftables или iptables. Установите один из этих firewall-инструментов."
  fi
}

service_action() {
  local action="$1"

  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl "${action}" zapret2.service
  elif [[ -x /etc/init.d/zapret2 ]]; then
    /etc/init.d/zapret2 "${action}"
  elif [[ -x "${ZAPRET2_DIR}/init.d/sysv/zapret2" ]]; then
    "${ZAPRET2_DIR}/init.d/sysv/zapret2" "${action}"
  else
    die "служба zapret2 не найдена. Сначала выполните install."
  fi
}

install_official_zapret2() {
  local archive_name="zapret2-v${ZAPRET2_VERSION}.tar.gz"
  local base_url="https://github.com/bol-van/zapret2/releases/download/v${ZAPRET2_VERSION}"
  local checksum_file="sha256sum.txt"
  local expected actual source_dir

  need_command curl
  need_command tar
  need_command sha256sum
  need_command awk
  need_command find
  need_command mktemp

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/void-scpsl.XXXXXXXX")"
  chmod 700 "${TEMP_DIR}"

  printf 'Скачивание официальной zapret2 v%s...\n' "${ZAPRET2_VERSION}"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "${TEMP_DIR}/${archive_name}" "${base_url}/${archive_name}"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "${TEMP_DIR}/${checksum_file}" "${base_url}/${checksum_file}"

  expected="$(awk -v file="${archive_name}" '$2 == file || $2 == "*" file {print $1; exit}' "${TEMP_DIR}/${checksum_file}")"
  [[ "${expected}" =~ ^[[:xdigit:]]{64}$ ]] || die "контрольная сумма ${archive_name} не найдена в официальном sha256sum.txt"
  actual="$(sha256sum "${TEMP_DIR}/${archive_name}" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA-256 официального архива не совпала"
  printf 'SHA-256 проверена: %s\n' "${actual}"

  mkdir -p "${TEMP_DIR}/extract"
  tar -xzf "${TEMP_DIR}/${archive_name}" -C "${TEMP_DIR}/extract"
  source_dir="$(find "${TEMP_DIR}/extract" -mindepth 1 -maxdepth 1 -type d -name 'zapret2-*' -print -quit)"
  [[ -n "${source_dir}" && -f "${source_dir}/install_easy.sh" ]] || die "в архиве не найден install_easy.sh"

  printf '\nСейчас запустится официальный интерактивный установщик zapret2.\n'
  printf 'Установите NFQWS2. После завершения профиль SCP:SL будет применён автоматически.\n\n'
  (
    cd -- "${source_dir}"
    bash ./install_easy.sh
  )

  [[ -f "${ZAPRET2_DIR}/config" ]] || die "официальный установщик не создал ${ZAPRET2_DIR}/config"
}

write_config_without_profile() {
  local source_config="$1"
  local target_config="$2"

  awk -v begin="${PROFILE_BEGIN}" -v end="${PROFILE_END}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "${source_config}" > "${target_config}"
}

backup_config() {
  local config="${ZAPRET2_DIR}/config"
  local backup="${ZAPRET2_DIR}/config.before-scpsl.$(date +%Y%m%d-%H%M%S).$$"

  cp -a -- "${config}" "${backup}"
  printf 'Резервная копия: %s\n' "${backup}"
}

apply_profile() {
  local config="${ZAPRET2_DIR}/config"
  local temp_config firewall

  [[ -f "${config}" ]] || die "не найден ${config}. Сначала выполните install."
  [[ -f "${PROFILE_FILE}" ]] || die "рядом со скриптом отсутствует scpsl.conf"
  need_command awk
  need_command sed
  need_command install
  need_command mktemp

  firewall="$(detect_firewall)"
  temp_config="$(mktemp "${ZAPRET2_DIR}/.config.void.XXXXXXXX")"
  backup_config
  write_config_without_profile "${config}" "${temp_config}"
  printf '\n' >> "${temp_config}"
  sed "s/^FWTYPE=__FWTYPE__$/FWTYPE=${firewall}/" "${PROFILE_FILE}" >> "${temp_config}"
  install -m 0644 -- "${temp_config}" "${config}"
  rm -f -- "${temp_config}"

  printf 'Профиль применён: Game Filter TCP+UDP = enabled, IPSet = any.\n'
  printf 'Linux-параметры: FWTYPE=%s, MODE_FILTER=none.\n' "${firewall}"
}

remove_profile() {
  local config="${ZAPRET2_DIR}/config"
  local temp_config

  [[ -f "${config}" ]] || die "не найден ${config}"
  need_command awk
  need_command install
  need_command mktemp

  temp_config="$(mktemp "${ZAPRET2_DIR}/.config.void.XXXXXXXX")"
  backup_config
  write_config_without_profile "${config}" "${temp_config}"
  install -m 0644 -- "${temp_config}" "${config}"
  rm -f -- "${temp_config}"
  printf 'Блок VOID PROJECT удалён. Сама zapret2 не удалялась.\n'
}

show_status() {
  local config="${ZAPRET2_DIR}/config"

  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status zapret2.service || true
  elif [[ -x /etc/init.d/zapret2 ]]; then
    /etc/init.d/zapret2 status || true
  elif [[ -x "${ZAPRET2_DIR}/init.d/sysv/zapret2" ]]; then
    "${ZAPRET2_DIR}/init.d/sysv/zapret2" status || true
  else
    printf 'Служба zapret2 не найдена.\n'
  fi

  if [[ -f "${config}" ]]; then
    printf '\nАктивные параметры SCP:SL:\n'
    grep -E '^(FWTYPE|MODE_FILTER|NFQWS2_ENABLE|NFQWS2_PORTS_TCP|NFQWS2_PORTS_UDP)=' "${config}" | tail -n 5 || true
  fi
}

test_one() {
  local name="$1"
  local url="$2"
  local output rc

  set +e
  output="$(curl --location --http1.1 \
    --connect-timeout 8 --max-time 15 \
    --user-agent 'UnityPlayer/2022.3 (UnityWebRequest/1.0, libcurl)' \
    --header 'Accept: application/json' \
    --output /dev/null \
    --write-out 'HTTP=%{http_code} IP=%{remote_ip} TLS=%{ssl_verify_result} TIME=%{time_total}s' \
    "${url}" 2>&1)"
  rc=$?
  set -e

  if [[ ${rc} -eq 0 ]]; then
    printf '[OK]   %-22s %s\n' "${name}" "${output}"
    return 0
  fi

  printf '[FAIL] %-22s curl=%s %s\n' "${name}" "${rc}" "${output}"
  return 1
}

run_tests() {
  local report failures=0

  need_command curl
  need_command tee
  report="${PWD}/test_results_linux_$(date +%Y-%m-%d_%H-%M-%S).txt"
  exec > >(tee -a "${report}") 2>&1

  printf 'Проверка центральных сервисов SCP:SL\n'
  printf 'Дата UTC: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"

  test_one 'scpslgame.com' 'https://scpslgame.com/' || failures=$((failures + 1))
  test_one 'api.scpslgame.com' 'https://api.scpslgame.com/' || failures=$((failures + 1))
  test_one 'servers.php' 'https://api.scpslgame.com/servers.php' || failures=$((failures + 1))
  test_one 'sbg1.scpslgame.com' 'https://sbg1.scpslgame.com/' || failures=$((failures + 1))
  test_one 'slac.scpslgame.com' 'https://slac.scpslgame.com/' || failures=$((failures + 1))

  printf '\nОтчёт: %s\n' "${report}"
  if [[ ${failures} -eq 0 ]]; then
    printf 'Сеть до всех проверяемых узлов доступна. Полностью перезапустите Steam и SCP:SL.\n'
    printf 'HTTP/TLS-доступ не гарантирует успешную авторизацию внутри игры.\n'
    return 0
  fi

  printf 'Не пройдено проверок: %s. Приложите этот отчёт и Player.log к обращению.\n' "${failures}"
  return 1
}

main() {
  local command="${1:-help}"
  banner

  case "${command}" in
    install)
      require_root "install"
      if [[ ! -f "${ZAPRET2_DIR}/config" ]]; then
        install_official_zapret2
      else
        printf 'Найдена установленная zapret2 в %s; повторное скачивание пропущено.\n' "${ZAPRET2_DIR}"
      fi
      apply_profile
      service_action restart
      printf '\nГотово. Полностью перезапустите Steam и SCP:SL, затем выполните без sudo: %s test\n' "$0"
      ;;
    apply)
      require_root "apply"
      apply_profile
      service_action restart
      ;;
    start|stop|restart)
      require_root "${command}"
      service_action "${command}"
      ;;
    status)
      show_status
      ;;
    test)
      run_tests
      ;;
    remove-profile)
      require_root "remove-profile"
      remove_profile
      service_action restart
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      die "неизвестная команда '${command}'"
      ;;
  esac
}

main "$@"
