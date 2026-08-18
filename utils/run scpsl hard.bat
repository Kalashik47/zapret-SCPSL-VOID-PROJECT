@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SCPSL_MODE=%~3"
if /i not "%SCPSL_MODE%"=="service_export" (
    chcp 65001 > nul
    call "%~dp0show void project.bat"
)

cd /d "%~dp0.."
if /i not "%SCPSL_MODE%"=="service_export" (
    call service.bat status_zapret
    call service.bat check_updates
    call service.bat load_game_filter
    call service.bat load_user_lists
    echo:
)

set "BIN=%~dp0..\bin\"
set "LISTS=%~dp0..\lists\"
set "PROFILE=%~1"
set "TITLE=%~2"
set "SCPSL_FILTER=--filter-tcp=80,443 --ipset="%LISTS%ipset-scpsl.txt""
cd /d "%BIN%"

goto profile_%PROFILE%

:profile_1
set "SCPSL_ARGS=--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=16 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000 --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin""
goto run

:profile_2
set "SCPSL_ARGS=--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000 --dpi-desync-repeats=16 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin""
goto run

:profile_3
set "SCPSL_ARGS=--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=664 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=14 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_max_ru.bin" --dpi-desync-fake-tls="%BIN%stun2.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_max_ru.bin" --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin""
goto run

:profile_4
set "SCPSL_ARGS=--dpi-desync=fake,fakedsplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=2 --dpi-desync-repeats=16 --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin""
goto run

:profile_5
set "SCPSL_ARGS=--dpi-desync=fake,fakedsplit --dpi-desync-repeats=14 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%BIN%stun.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin""
goto run

:profile_6
set "SCPSL_ARGS=--dpi-desync=fake,hostfakesplit --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ya.ru --dpi-desync-hostfakesplit-mod=host=ya.ru,altorder=1 --dpi-desync-fooling=ts --dpi-desync-repeats=12 --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin""
goto run

:profile_7
set "SCPSL_ARGS=--dpi-desync=multisplit --dpi-desync-split-pos=2,sniext+1 --dpi-desync-split-seqovl=679 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin""
goto run

:profile_8
set "SCPSL_ARGS=--dpi-desync=hostfakesplit --dpi-desync-repeats=12 --dpi-desync-fooling=ts,md5sig --dpi-desync-hostfakesplit-mod=host=ozon.ru"
goto run

:profile_9
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=multidisorder --dpi-desync-split-pos=2"
goto run

:profile_10
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-ttl=3 --dpi-desync-repeats=8 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_11
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fakedsplit --dpi-desync-ttl=1 --dpi-desync-autottl=3 --dpi-desync-split-pos=midsld"
goto run

:profile_12
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=syndata,multisplit --dpi-desync-fake-syndata=@"%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-split-pos=1,midsld"
goto run

:profile_13
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-fooling=datanoack --dpi-desync-repeats=8 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin""
goto run

:profile_14
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake,multidisorder --dpi-desync-fooling=datanoack --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=8 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin""
goto run

:profile_15
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fakeddisorder --dpi-desync-ttl=3 --dpi-desync-split-pos=1"
goto run

:profile_16
set "SCPSL_FILTER=--filter-l3=ipv4 --filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_17
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_18
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-repeats=12 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_19
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-repeats=16 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_20
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n3 --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_21
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-ttl=3 --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_22
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_23
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake,multisplit --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=681 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_24
set "SCPSL_FILTER=--filter-tcp=80,443"
set "SCPSL_ARGS=--dpi-desync=fake,multidisorder --dpi-desync-fooling=md5sig --dpi-desync-repeats=8 --dpi-desync-split-pos=1,midsld --dpi-desync-fake-tls-mod=rnd,dupsid,rndsni,padencap"
goto run

:profile_error
echo [ERROR] Unknown SCP:SL hard profile: %PROFILE%
exit /b 2

:run
if /i "%SCPSL_MODE%"=="service_export" (
    endlocal & set "SCPSL_FILTER=%SCPSL_FILTER%" & set "SCPSL_ARGS=%SCPSL_ARGS%"
    exit /b 0
)

start "zapret: %TITLE%" /min "%BIN%winws.exe" --wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp=443,19294-19344,50000-50100,%GameFilterUDP% ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%BIN%ACTIVE_DISCORD_UDP.bin" --dpi-desync-fake-stun="%BIN%ACTIVE_DISCORD_UDP.bin" --dpi-desync-repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --ip-id=zero --dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --new ^
%SCPSL_FILTER% %SCPSL_ARGS% --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-scpsl.txt" %SCPSL_ARGS% --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_4pda_to.bin" --new ^
--filter-udp=443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-tcp=80,443,8443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_4pda_to.bin" --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n3 --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_4pda_to.bin" --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=12 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%ACTIVE_GAME_UDP.bin" --dpi-desync-cutoff=n2
exit /b 0
