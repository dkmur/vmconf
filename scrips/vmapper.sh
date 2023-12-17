#!/system/bin/sh
# version 14.8.8

#Version checks
Ver49vmapper="1.7.1"
Ver56vmwatchdog="1.3.9"
VerATVwebhook="2.1.2"

#Create logfile
if [ ! -e /sdcard/vm.log ] ;then
   touch /sdcard/vm.log
fi

# remove old vmapper_conf file if exists
rm -f /sdcard/vmapper_conf

logfile="/sdcard/vm.log"
vmconf="/data/data/de.vahrmap.vmapper/shared_prefs/config.xml"
lastResort="/data/local/vm_last_resort"
current_mac=$(ifconfig eth0 | awk '/HWaddr/{print $5}')
current_mac_encoded=$(echo $current_mac | sed 's/:/%3A/g') # URL-kodiere die MAC-Adresse

# stderr to logfile
exec 2>> $logfile

# add vmapper.sh command to log
echo "" >> $logfile
echo "`date +%Y-%m-%d_%T` ## Executing $(basename $0) $@" >> $logfile

#Check if using Develop or main
if [ -f /sdcard/useVMCdevelop ] ;then
   branch="https://raw.githubusercontent.com/v-mapper/vmconf/develop9/scrips"
else
   branch="https://raw.githubusercontent.com/v-mapper/vmconf/main9/scrips"
fi

########## Functions

reboot_device(){
   echo "`date +%Y-%m-%d_%T` Reboot device" >> $logfile
   sleep 2
   /system/bin/reboot
}

case "$(uname -m)" in
   aarch64) arch="arm64_v8a";;
   armv8l)  arch="armeabi-v7a";;
esac

checkupdate(){

   function ver {
      for i in $(echo "$1" | tr '.' ' ')
      do
         echo $i | awk '{ printf("%03d", $1) }';
      done
   }

   if [ $(ver $1) -lt $(ver $2) ]; then
      need_update=1
   else
      need_update=0
   fi

}

install_vmapper_wizard(){
   # we first download vmapper
   /system/bin/rm -f /sdcard/Download/vmapper.apk
   until /system/bin/curl -k -s -L --fail --show-error -o /sdcard/Download/vmapper.apk -u $authuser:$authpassword "$server/apk/vmapperd/download" || { echo "`date +%Y-%m-%d_%T` Download vmapper failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done

   # let us kill pogo as well
   am force-stop com.nianticlabs.pokemongo

   ## Install vmapper
   settings put global package_verifier_user_consent -1
   /system/bin/pm install -r /sdcard/Download/vmapper.apk
   /system/bin/rm -f /sdcard/Download/vmapper.apk
   echo "`date +%Y-%m-%d_%T` VM install: vmapper installed" >> $logfile

   ## At this stage vmapper isn't in magisk db nor had it generated a config folder
   am start -n de.vahrmap.vmapper/.MainActivity
   sleep 20
   uid=$(stat -c %u /data/data/de.vahrmap.vmapper/)
   am force-stop de.vahrmap.vmapper
   sleep 2

   ## Grant su access
   magisk --sqlite "REPLACE INTO policies (uid, policy, until, logging, notification) VALUES (\"$uid\", 2, 0, 1, 1);"
   echo "`date +%Y-%m-%d_%T` VM install: vmapper granted su" >> $logfile

   ## Create config file
   create_vmapper_xml

   ## Start vmapper
   am broadcast -n de.vahrmap.vmapper/.RestartService
   sleep 5

   # add 56vmwatchdog for new install on PoGoRom
   if [ ! -f /system/etc/init.d/56vmwatchdog ] ;then
      mount -o remount,rw /
      until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/56vmwatchdog $branch/56vmwatchdog || { echo "`date +%Y-%m-%d_%T` VM install: download 56vmwatchdog failed, exit" >> $logfile ; exit 1; } ;do
         sleep 2
      done
      chmod +x /system/etc/init.d/56vmwatchdog
      #  mount -o remount,ro /
      echo "`date +%Y-%m-%d_%T` VM install: 56vmwatchdog installed" >> $logfile
   fi

   # add webhooksender
   mount -o remount,rw /
   until /system/bin/curl -s -k -L --fail --show-error -o /system/bin/ATVdetailsSender.sh $branch/ATVdetailsSender.sh || { echo "`date +%Y-%m-%d_%T` VM install: download ATVdetailsSender.sh failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   chmod +x /system/bin/ATVdetailsSender.sh
   echo "`date +%Y-%m-%d_%T` VM install: webhook sender installed" >> $logfile
   mount -o remount,ro /

   ## Set for reboot device
   reboot=1
}

vmapper_wizard(){
   #check update vmapper and download from wizard
   newver="$(/system/bin/curl -s -k -L -u $authuser:$authpassword   "$server/get_apk_versions_info"| jq -r '.["vmapperd.apk"]' | sed 's/^V//;s/D$//')"
   installedver="$(dumpsys package de.vahrmap.vmapper | grep versionName | head -n1 | sed 's/ *versionName=//' | sed 's/^V//;s/D$//')"

   if [ "$newver" = "" ] ;then
      vm_install="skip"
      echo "`date +%Y-%m-%d_%T` Vmapper not found in Genesect, skipping version check" >> $logfile
   else
      checkupdate "$installedver" "$newver"
      if [ $need_update -eq 1 ]; then
        echo "`date +%Y-%m-%d_%T` New vmapper version detected in wizard, updating $installedver=>$newver" >> $logfile
        /system/bin/rm -f /sdcard/Download/vmapper.apk
        until /system/bin/curl -k -s -L --fail --show-error -o /sdcard/Download/vmapper.apk -u $authuser:$authpassword "$server/apk/vmapperd/download" || { echo "`date +%Y-%m-%d_%T` Download vmapper failed, exit" >> $logfile ; exit 1; } ;do
           sleep 2
        done

        # set vmapper to be installed
        vm_install="install"
      else
         vm_install="skip"
         echo "`date +%Y-%m-%d_%T` Vmapper already on latest version" >> $logfile
      fi
   fi
}

update_vmapper_wizard(){
   vmapper_wizard
   if [ "$vm_install" = "install" ]; then
      echo "`date +%Y-%m-%d_%T` Installing vmapper" >> $logfile
      # install vmapper
      /system/bin/pm install -r /sdcard/Download/vmapper.apk
      /system/bin/rm -f /sdcard/Download/vmapper.apk

      reboot=1
   fi
}

downgrade_vmapper_wizard(){
   # we download first
   /system/bin/rm -f /sdcard/Download/vmapper.apk
   until /system/bin/curl -k -s -L --fail --show-error -o /sdcard/Download/vmapper.apk -u $authuser:$authpassword   "$server/apk/vmapperd/download" || { echo "`date +%Y-%m-%d_%T` Download vmapper failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   # remove vmapper
   am force-stop com.nianticlabs.pokemongo
   am force-stop de.vahrmap.vmapper
   sleep 2
   /system/bin/pm uninstall de.vahrmap.vmapper
   echo "`date +%Y-%m-%d_%T` VM downgrade: vmapper removed" >> $logfile

   # install vmapper from wizard
   /system/bin/pm install -r /sdcard/Download/vmapper.apk
   /system/bin/rm -f /sdcard/Download/vmapper.apk
   echo "`date +%Y-%m-%d_%T` VM downgrade: vmapper installed" >> $logfile

   # grant SU
   am start -n de.vahrmap.vmapper/.MainActivity
   sleep 20
   uid=$(stat -c %u /data/data/de.vahrmap.vmapper/)
   am force-stop de.vahrmap.vmapper
   sleep 2
   magisk --sqlite "REPLACE INTO policies (uid, policy, until, logging, notification) VALUES (\"$uid\", 2, 0, 1, 1);"
   echo "`date +%Y-%m-%d_%T` VM downgrade: vmapper granted SU access" >> $logfile

   # (re)create xml and start vmapper+pogo
   create_vmapper_xml_no_reboot
   echo "`date +%Y-%m-%d_%T` VM downgrade: xml re-created and vmapper+pogo re-started" >> $logfile
}

pogo_wizard(){
   #check pogo and download from wizard

   if [ -z ${force_pogo_update+x} ] ;then
      newver="$(/system/bin/curl -s -k -L -u $authuser:$authpassword   "$server/get_apk_versions_info" | jq -r '.["pogo.apk"]')"
   else
      newver="1.599.1"
   fi
   installedver="$(dumpsys package com.nianticlabs.pokemongo|awk -F'=' '/versionName/{print $2}')"

   checkupdate "$installedver" "$newver"
   if [ $need_update -eq 1 ]; then
      echo "`date +%Y-%m-%d_%T` New pogo version detected in wizard, updating $installedver=>$newver" >> $logfile
      /system/bin/rm -f /sdcard/Download/pogo.apk
      until /system/bin/curl -k -s -L --fail --show-error -o /sdcard/Download/pogo.apk -u $authuser:$authpassword   "$server/apk/pogo/download" || { echo "`date +%Y-%m-%d_%T` Download pogo failed, exit" >> $logfile ; exit 1; } ;do
         sleep 2
      done

      # set pogo to be installed
      pogo_install="install"

   else
      pogo_install="skip"
      echo "`date +%Y-%m-%d_%T` PoGo already on latest version" >> $logfile
   fi
}

update_pogo_wizard(){
   pogo_wizard
   if [ "$pogo_install" = "install" ] ;then
      echo "`date +%Y-%m-%d_%T` Installing pogo" >> $logfile
      # install pogo
      /system/bin/pm install -r /sdcard/Download/pogo.apk
      /system/bin/rm -f /sdcard/Download/pogo.apk
      reboot=1
   fi
}

downgrade_pogo_wizard_no_reboot(){
   /system/bin/rm -f /sdcard/Download/pogo.apk
   until /system/bin/curl -k -s -L --fail --show-error -o /sdcard/Download/pogo.apk -u $authuser:$authpassword   "$server/apk/pogo/download" || { echo "`date +%Y-%m-%d_%T` Download pogo failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   echo "`date +%Y-%m-%d_%T` PoGo downgrade: pogo downloaded from wizard" >> $logfile
   /system/bin/pm uninstall com.nianticlabs.pokemongo
   echo "`date +%Y-%m-%d_%T` PoGo downgrade: pogo removed" >> $logfile
   /system/bin/pm install -r /sdcard/Download/pogo.apk
   /system/bin/rm -f /sdcard/Download/pogo.apk
   echo "`date +%Y-%m-%d_%T` PoGo downgrade: pogo installed" >> $logfile
   monkey -p com.nianticlabs.pokemongo -c android.intent.category.LAUNCHER 1
   echo "`date +%Y-%m-%d_%T` PoGo downgrade: pogo started" >> $logfile
}

vmapper_xml(){
   vmconf="/data/data/de.vahrmap.vmapper/shared_prefs/config.xml"
   vmuser=$(ls -la /data/data/de.vahrmap.vmapper/|head -n2|tail -n1|awk '{print $3}')

   until /system/bin/curl -k -s -L --fail --show-error -o $vmconf -u $authuser:$authpassword   "$server/vm_conf?mac=$current_mac_encoded"|| { echo "`date +%Y-%m-%d_%T` Download config.xml failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done

   chmod 660 $vmconf
   chown $vmuser:$vmuser $vmconf
   echo "`date +%Y-%m-%d_%T` Vmapper config.xml (re)created" >> $logfile
}

create_vmapper_xml(){
   vmapper_xml
   reboot=1
}

create_vmapper_xml_no_reboot(){
   vmapper_xml
   echo "`date +%Y-%m-%d_%T` Restarting vmapper and pogo" >> $logfile
   am force-stop com.nianticlabs.pokemongo
   am force-stop de.vahrmap.vmapper
   am broadcast -n de.vahrmap.vmapper/.RestartService
   sleep 5
   monkey -p com.nianticlabs.pokemongo -c android.intent.category.LAUNCHER 1
}

force_pogo_update(){
   force_pogo_update=true
}

update_all(){
   if [ -f /sdcard/disableautovmapperupdate ] ;then
      echo "`date +%Y-%m-%d_%T` VMapper auto update disabled, skipping version check" >> $logfile
   else
      vmapper_wizard
   fi

   if [ -f /sdcard/disableautopogoupdate ] ;then
      echo "`date +%Y-%m-%d_%T` PoGo auto update disabled, skipping version check" >> $logfile
   else
      pogo_wizard
   fi

   if [ ! -z "$vm_install" ] && [ ! -z "$pogo_install" ] ;then
      echo "`date +%Y-%m-%d_%T` All updates checked and downloaded if needed" >> $logfile
      if [ "$vm_install" = "install" ] ;then
        echo "`date +%Y-%m-%d_%T` Install vmapper" >> $logfile
        # kill pogo
        am force-stop com.nianticlabs.pokemongo
        # install vmapper
        /system/bin/pm install -r /sdcard/Download/vmapper.apk
        /system/bin/rm -f /sdcard/Download/vmapper.apk
        # if no pogo update we restart both now
        if [ "$pogo_install" != "install" ] ;then
           echo "`date +%Y-%m-%d_%T` No pogo update, starting vmapper+pogo" >> $logfile
           am force-stop de.vahrmap.vmapper
           am broadcast -n de.vahrmap.vmapper/.RestartService
           sleep 5
           monkey -p com.nianticlabs.pokemongo -c android.intent.category.LAUNCHER 1
        fi
      fi
      if [ "$pogo_install" = "install" ] ;then
        echo "`date +%Y-%m-%d_%T` Install pogo, restart vmapper and start pogo" >> $logfile
        # install pogo
        /system/bin/pm install -r /sdcard/Download/pogo.apk
        /system/bin/rm -f /sdcard/Download/pogo.apk
        # restart vmapper + start pogo
        am force-stop de.vahrmap.vmapper
        am broadcast -n de.vahrmap.vmapper/.RestartService
        sleep 5
        monkey -p com.nianticlabs.pokemongo -c android.intent.category.LAUNCHER 1
      fi
      if [ "$vm_install" != "install" ] && [ "$pogo_install" != "install" ] ;then
        echo "`date +%Y-%m-%d_%T` Nothing to install" >> $logfile
      fi
   fi
}

send_logs(){
   if [[ -z $webhook ]] ;then
      echo "`date +%Y-%m-%d_%T` Vmapper: no webhook set in job" >> $logfile
   else
      # vmapper log
      curl -S -k -L --fail --show-error -F "payload_json={\"username\": \"vmconf log sender\", \"content\": \"vm.log for $origin\"}" -F "file1=@$logfile" $webhook &>/dev/null
      # rom_install log
      [[ -f /sdcard/initrom/rom_install.log ]] && curl -S -k -L --fail --show-error -F "payload_json={\"username\": \"vmconf rom_install log sender\", \"content\": \"rom_install.log for $origin\"}" -F "file1=@/sdcard/initrom/rom_install.log" $webhook &>/dev/null
      # vmconf log
      curl -S -k -L --fail --show-error -F "payload_json={\"username\": \"vmconf log sender\", \"content\": \"vmapper.log for $origin\"}" -F "file1=@/sdcard/vmapper.log" $webhook &>/dev/null
      #logcat
      logcat -d > /sdcard/logcat.txt
      curl -S -k -L --fail --show-error -F "payload_json={\"username\": \"vmconf log sender\", \"content\": \"logcat.txt for $origin\"}" -F "file1=@/sdcard/logcat.txt" $webhook &>/dev/null
      rm -f /sdcard/logcat.txt
      echo "`date +%Y-%m-%d_%T` Vmapper: sending logs to discord" >> $logfile
   fi
}

update_a9_rom(){
   mount -o remount,rw /

   # update 56vmwatchdog
   until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/56vmwatchdog $branch/56vmwatchdog || { echo "`date +%Y-%m-%d_%T` VM install: download 56vmwatchdog failed, exit" >> $logfile ; exit 1; } ;do
       sleep 2
   done
   chmod +x /system/etc/init.d/56vmwatchdog
   echo "`date +%Y-%m-%d_%T` VM install: 56vmwatchdog updated" >> $logfile

   # update webhooksender
   until /system/bin/curl -s -k -L --fail --show-error -o /system/bin/ATVdetailsSender.sh $branch/ATVdetailsSender.sh || { echo "`date +%Y-%m-%d_%T` VM install: download ATVdetailsSender.sh failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   chmod +x /system/bin/ATVdetailsSender.sh
   echo "`date +%Y-%m-%d_%T` VM install: webhook sender updated" >> $logfile

   # update 49vmapper
   until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/49vmapper $branch/49vmapper || { echo "`date +%Y-%m-%d_%T` VM install: download 49vmapper failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   chmod +x /system/etc/init.d/49vmapper
   echo "`date +%Y-%m-%d_%T` VM install: 49vmapper updated" >> $logfile

   # update 28playfixswitch
   until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/28playfixswitch $branch/28playfixswitch || { echo "`date +%Y-%m-%d_%T` VM install: download 28playfixswitch failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   chmod +x /system/etc/init.d/28playfixswitch
   echo "`date +%Y-%m-%d_%T` VM install: 28playfixswitch updated" >> $logfile

   mount -o remount,ro / 
}



########## Execution

#remove old last resort
rm -f /sdcard/vm_last_resort

#wait on internet
until ping -c1 8.8.8.8 >/dev/null 2>/dev/null || ping -c1 1.1.1.1 >/dev/null 2>/dev/null; do
   sleep 10
done
echo "`date +%Y-%m-%d_%T` Internet connection available" >> $logfile

# Initial Install of 56vmwatchdog
if [ ! -f /system/etc/init.d/56vmwatchdog ] ;then
   mount -o remount,rw /
   until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/56vmwatchdog $branch/56vmwatchdog || { echo "`date +%Y-%m-%d_%T` VM install: download 56vmwatchdog failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   chmod +x /system/etc/init.d/56vmwatchdog
   #  mount -o remount,ro /
   echo "`date +%Y-%m-%d_%T` VM install: 56vmwatchdog installed" >> $logfile
fi

#download latest vmapper.sh
if [[ $(basename $0) != "vmapper_new.sh" ]] ;then
   mount -o remount,rw /
   oldsh=$(head -2 /system/bin/vmapper.sh | grep '# version' | awk '{ print $NF }')
   until /system/bin/curl -s -k -L --fail --show-error -o /system/bin/vmapper_new.sh $branch/vmapper.sh || { echo "`date +%Y-%m-%d_%T` Download vmapper.sh failed, exit" >> $logfile ; exit 1; } ;do
      sleep 2
   done
   chmod +x /system/bin/vmapper_new.sh
   newsh=$(head -2 /system/bin/vmapper_new.sh | grep '# version' | awk '{ print $NF }')
   if [[ $oldsh != $newsh ]] ;then
      echo "`date +%Y-%m-%d_%T` vmapper.sh $oldsh=>$newsh, restarting script" >> $logfile
      #   folder=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
      cp /system/bin/vmapper_new.sh /system/bin/vmapper.sh
      mount -o remount,ro /
      /system/bin/vmapper_new.sh $@
      exit 1
   fi
fi

#update 49vmapper, 56vmwatchdog and ATVdetailsSender.sh if needed
if [[ $(basename $0) = "vmapper_new.sh" ]] ;then
   mount -o remount,rw /

   #download latest 49vmapper if used
   if [[ -f /system/etc/init.d/49vmapper ]] ;then
      old49=$(head -2 /system/etc/init.d/49vmapper | grep '# version' | awk '{ print $NF }')
      if [ $Ver49vmapper != $old49 ] ;then
        until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/49vmapper $branch/49vmapper || { echo "`date +%Y-%m-%d_%T` Download 49vmapper failed, exit" >> $logfile ; exit 1; } ;do
           sleep 2
        done
        chmod +x /system/etc/init.d/49vmapper
        new49=$(head -2 /system/etc/init.d/49vmapper | grep '# version' | awk '{ print $NF }')
        echo "`date +%Y-%m-%d_%T` 49vmapper $old49=>$new49" >> $logfile
      fi
   fi

   #download latest 56vmwatchdog if used
   if [[ -f /system/etc/init.d/56vmwatchdog ]] ;then
      old56=$(head -2 /system/etc/init.d/56vmwatchdog | grep '# version' | awk '{ print $NF }')
      if [ $Ver56vmwatchdog != $old56 ] ;then
        until /system/bin/curl -s -k -L --fail --show-error -o /system/etc/init.d/56vmwatchdog $branch/56vmwatchdog || { echo "`date +%Y-%m-%d_%T` Download 56vmwatchdog failed, exit" >> $logfile ; exit 1; } ;do
           sleep 2
        done
        chmod +x /system/etc/init.d/56vmwatchdog
        new56=$(head -2 /system/etc/init.d/56vmwatchdog | grep '# version' | awk '{ print $NF }')
        echo "`date +%Y-%m-%d_%T` 56vmwatchdog $old56=>$new56" >> $logfile
      fi
   fi

   #download latest ATVdetailsSender.sh
   oldWH=$([ -f /system/bin/ATVdetailsSender.sh ] && head -2 /system/bin/ATVdetailsSender.sh | grep '# version' | awk '{ print $NF }' || echo 0)
   if [ $VerATVwebhook != $oldWH ] ;then
      until /system/bin/curl -s -k -L --fail --show-error -o /system/bin/ATVdetailsSender.sh $branch/ATVdetailsSender.sh || { echo "`date +%Y-%m-%d_%T` Download ATVdetailsSender.sh failed, exit" >> $logfile ; exit 1; } ;do
        sleep 2
      done
      chmod +x /system/bin/ATVdetailsSender.sh
      newWH=$(head -2 /system/bin/ATVdetailsSender.sh | grep '# version' | awk '{ print $NF }')
      echo "`date +%Y-%m-%d_%T` ATVdetailsSender.sh $oldWH=>$newWH" >> $logfile
   fi
   mount -o remount,ro /
fi

# check vmapper policy
if [ -d /data/data/de.vahrmap.vmapper/ ] ;then
   uid=$(stat -c %u /data/data/de.vahrmap.vmapper/)
   policy=$(sqlite3 /data/adb/magisk.db "SELECT policy FROM policies where uid = '$uid'")
   if [[ $policy == "" ]] ;then
      echo "`date +%Y-%m-%d_%T` vmapper incorectly or not added to su list, adding it and reboot device" >> $logfile
      sqlite3 /data/adb/magisk.db "DELETE FROM policies where uid = '$uid'"
      sqlite3 /data/adb/magisk.db "INSERT INTO policies (uid,policy,until,logging,notification) VALUES('$uid',2,0,1,1)"
      reboot=1
   else
      if [[ $policy != 2 ]] ;then
        echo "`date +%Y-%m-%d_%T` incorrect policy for vmapper, changing it and reboot device" >> $logfile
        sqlite3 /data/adb/magisk.db "DELETE FROM policies where uid = '$uid'"
        sqlite3 /data/adb/magisk.db "INSERT INTO policies (uid,until,logging,notification) VALUES('$uid',2,0,1,1)"
        reboot=1
      fi
   fi
fi

# allign settings with vm
[ -f $vmconf ] && vm_origin=$(grep -w 'origin' $vmconf | sed -e 's/    <string name="origin">\(.*\)<\/string>/\1/')
[ -f $vmconf ] && vm_ws=$(grep -w 'websocketurl' $vmconf | sed -e 's/    <string name="websocketurl">\(.*\)<\/string>/\1/')
[ -f $vmconf ] && vm_dest=$(grep -w 'postdest' $vmconf | sed -e 's/    <string name="postdest">\(.*\)<\/string>/\1/')

# check owner of vmapper config.xml
[ -f $vmconf ] && vmuser=$(ls -la /data/data/de.vahrmap.vmapper/|head -n2|tail -n1|awk '{print $3}')
[ -f $vmconf ] && vmconfiguser=$(ls -la /data/data/de.vahrmap.vmapper/shared_prefs/config.xml |head -n2|tail -n1|awk '{print $3}')
if [ -f "$vmconf" ] && [[ $vmuser != $vmconfiguser ]] ;then
   chmod 660 $vmconf
   chown $vmuser:$vmuser $vmconf
   am force-stop de.vahrmap.vmapper
   am broadcast -n de.vahrmap.vmapper/.RestartService
   echo "`date +%Y-%m-%d_%T` VMconf check: vmapper config.xml user incorrect, changed it and restarted vmapper" >> $logfile
fi

# Get Genesect credentials and origin
if [ -f "$vmconf" ] && [ ! -z $(grep -w 'postdest' $vmconf | sed -e 's/    <string name="postdest">\(.*\)<\/string>/\1/') ] ;then
   server=$(grep -w 'postdest' $vmconf | sed -e 's/    <string name="postdest">\(.*\)<\/string>/\1/')
   authuser=$(grep -w 'authuser' $vmconf | sed -e 's/    <string name="authuser">\(.*\)<\/string>/\1/')
   authpassword=$(grep -w 'authpassword' $vmconf | sed -e 's/    <string name="authpassword">\(.*\)<\/string>/\1/')
   origin=$(grep -w 'origin' $vmconf | sed -e 's/    <string name="origin">\(.*\)<\/string>/\1/')
   echo "`date +%Y-%m-%d_%T` Using vahrmap.vmapper settings" >> $logfile
elif [ -f "$lastResort" ] ;then
   server=$(awk '{print $1}' "$lastResort")
   authuser=$(awk '{print $2}' "$lastResort")
   authpassword=$(awk '{print $3}' "$lastResort")
   origin=$(awk '{print $4}' "$lastResort")
   echo "`date +%Y-%m-%d_%T` Using settings stored in /sdcard/vm_last_resort"  >> $logfile
elif [[ -f /data/local/vmconf ]] ;then
   server=$(grep -w 'postdest' /data/local/vmconf | sed -e 's/    <string name="postdest">\(.*\)<\/string>/\1/')
   authuser=$(grep -w 'authuser' /data/local/vmconf | sed -e 's/    <string name="authuser">\(.*\)<\/string>/\1/')
   authpassword=$(grep -w 'authpassword' /data/local/vmconf | sed -e 's/    <string name="authpassword">\(.*\)<\/string>/\1/')
   auth="$authuser:$authpassword"
   origin=$(grep -w 'origin' /data/local/vmconf | sed -e 's/    <string name="origin">\(.*\)<\/string>/\1/')
   #pm disable-user com.android.vending
   echo "`date +%Y-%m-%d_%T` Using settings stored in /data/local/vmconf"  >> $logfile
else
   echo "`date +%Y-%m-%d_%T` No settings found to connect to Genesect, exiting vmapper.sh" >> $logfile
   echo "No settings found to connect to Genesect, exiting vmapper.sh"
   exit 1
fi

# verify endpoint and store settings as last resort
statuscode=$(/system/bin/curl -k -s -L --fail --show-error -o /dev/null -u $authuser:$authpassword "$server/vm_conf?mac=$current_mac_encoded" -w '%{http_code}')
if [ $statuscode != 200 ] ;then
   echo "Unable to reach Genesect endpoint, status code $statuscode, exit vmapper.sh"
   echo "`date +%Y-%m-%d_%T` Unable to reach Genesect endpoint, status code $statuscode, exiting vmapper.sh" >> $logfile
   exit 1
else
   /system/bin/rm -f "$lastResort"
   touch "$lastResort"
   echo "$server $authuser $authpassword $origin" >> "$lastResort"
fi

# prevent vmconf causing reboot loop. Bypass check by executing, vmapper.sh -nrc -whatever
if [ -z $1 ] || [ $1 != "-nrc" ] ;then
   if [ $(cat /sdcard/vm.log | grep `date +%Y-%m-%d` | grep rebooted | wc -l) -gt 20 ] ;then
      echo "`date +%Y-%m-%d_%T` Device rebooted over 20 times today, vmapper.sh signing out, see you tomorrow"  >> $logfile
      echo "Device rebooted over 20 times today, vmapper.sh signing out, see you tomorrow.....add -nrc to job or (re)move /sdcard/vm.log then try again"
      exit 1
   fi
fi

# set hostname = origin, wait till next reboot for it to take effect
if [ $(cat /system/build.prop | grep net.hostname | wc -l) = 0 ]; then
   echo "`date +%Y-%m-%d_%T` No hostname set, setting it to $origin" >> $logfile
   mount -o remount,rw /
   echo "net.hostname=$origin" >> /system/build.prop
   mount -o remount,ro /
else
   hostname=$(grep net.hostname /system/build.prop | awk 'BEGIN { FS = "=" } ; { print $2 }')
   if [[ $hostname != $origin ]] ;then
      echo "`date +%Y-%m-%d_%T` Changing hostname, from $hostname to $origin" >> $logfile
      mount -o remount,rw /
      sed -i -e "s/^net.hostname=.*/net.hostname=$origin/g" /system/build.prop
      mount -o remount,ro /
   fi
fi

# check for webhook
if [[ $2 == https://* ]] ;then
  webhook=$2
fi

# enable ATVdetails webhook sender or restart
if [ -f /data/local/ATVdetailsWebhook.config ] && [ -f /system/bin/ATVdetailsSender.sh ] && [ -f /sdcard/sendwebhook ] ;then
   checkWHsender=$(pgrep -f ATVdetailsSender.sh)
   if [ -z $checkWHsender ] ;then
      /system/bin/ATVdetailsSender.sh >/dev/null 2>&1 &
      echo "`date +%Y-%m-%d_%T` ATVdetails sender enabled" >> $logfile
   else
      kill -9 $checkWHsender
      sleep 2
      /system/bin/ATVdetailsSender.sh >/dev/null 2>&1 &
      echo "`date +%Y-%m-%d_%T` ATVdetails sender restarted" >> $logfile
   fi
fi

# hide both status and nav bar
settings put global policy_control immersive.full=*

for i in "$@" ;do
   case "$i" in
      -ivw) install_vmapper_wizard ;;
      -uvw) update_vmapper_wizard ;;
      -dvw) downgrade_vmapper_wizard ;;
      -upw) update_pogo_wizard ;;
      -dpwnr) downgrade_pogo_wizard_no_reboot ;;
      -ua) update_all ;;
      -uvx) create_vmapper_xml ;;
      -uvxnr) create_vmapper_xml_no_reboot ;;
      -fp) force_pogo_update ;;
      -sl) send_logs ;;
      -urom) update_a9_rom;;
   esac
done


(( $reboot )) && reboot_device
exit
