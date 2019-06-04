#!/bin/bash
TEST_RUN=false

# W3 times out during validation
seconds_to_slowdown_validation=.5
seconds_for_a_pause_validation=1


if [[ -z $1 || -z $2 ]]; then
    echo -e "\n\n\t For production use:"
    echo -e "\t\t ./run.sh /drupal/directory /path/to/folder \n"
    echo -e "\n\t For use in vagrant:"
    echo -e "\t\t ./run.sh /var/www/drupal /vagrant\n"
    exit
fi

clear
DRUPAL_HOME_DIR="${1%/}"
WORKING_HOME_DIR="${2%/}"
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TODAY=$(date)
HOST=$(hostname)
DRUSH=$(which drush)
three_errors="${WORKING_HOME_DIR}/automated_ingesting/3_errors"
two_ready_for_processing="${WORKING_HOME_DIR}/automated_ingesting/2_ready_for_processing"
four_completed="${WORKING_HOME_DIR}/automated_ingesting/4_completed"

INGESTION_STARTED=0
WORKING_TMP=0
WORKING_TMP_DIR=""

# In case process is terminated.
function cleanup_files {
  [ -f '/tmp/oai_dc.xsd' ] && rm -f /tmp/oai_dc.xsd
  [ -f '/tmp/mods-3-5.xsd' ] && rm -f /tmp/mods-3-5.xsd
  [ -f '/tmp/simpledc20021212.xsd' ] && rm -f /tmp/simpledc20021212.xsd
  [ -f '/tmp/*_MODS.xml' ] && rm -rf /tmp/*_MODS.xml
  echo -e "\n\tProcess terminated. EXIT signal recieved.\n\n"
  [ -d "${three_errors}" ] && echo -e "Process terminated. EXIT signal recieved." >> "${three_errors}/problems_with_start.txt"
  [ $WORKING_TMP == 0 ] || rm -rf "${WORKING_TMP_DIR}"
  rm -rf /tmp/*_MODS.xml
  rm -rf /tmp/*_DC.xml
}

trap cleanup_files EXIT
if [ ! -d "${DRUPAL_HOME_DIR}" ]; then
   echo "No drupal"
   exit
fi

size_needed=$(du -s "${WORKING_HOME_DIR}/automated_ingesting/2_ready_for_processing" | cut -f 1 -d "/")
size_available=$(df --output=avail -B 1 "/" |tail -n 1)
if [[ $size_needed -gt $size_available ]]; then
  echo "Not enough space available to process"
  exit
fi


# Download xsd schema
[ -f /tmp/oai_dc.xsd ] || curl -L "http://www.openarchives.org/OAI/2.0/oai_dc.xsd" --output "/tmp/oai_dc.xsd"
[ -f /tmp/mods-3-5.xsd ] || curl -L "http://www.loc.gov/standards/mods/v3/mods-3-5.xsd" --output "/tmp/mods-3-5.xsd"
[ -f /tmp/simpledc20021212.xsd ] || curl -L "http://dublincore.org/schemas/xmls/simpledc20021212.xsd" --output "/tmp/simpledc20021212.xsd"

# Replace url with string to downloaded version.
sed 's#http://dublincore.org/schemas/xmls/simpledc20021212.xsd#/tmp/simpledc20021212.xsd#g' /tmp/oai_dc.xsd

cd $WORKING_HOME_DIR

rm -f ${three_errors}/problems_with_start.txt

CHECK_MARK="\033[0;32m\xE2\x9C\x94\033[0m"
clear

echo -e "\n\n\n+---------------------------------------------------------------------------------------------------+\n"
echo -e "+---------------------------------------------------------------------------------------------------+\n\n"

cat << "EOF"



       _______       ________   _____ __     _________   ________
       ___    |      ____  _/   __  // /     __  ____/   ___  __ \
       __  /| |       __  /     _  // /_     _  /        __  /_/ /
       _  ___ |      __/ /      /__  __/     / /___      _  ____/
       /_/  |_|      /___/        /_/        \____/      /_/

                                                             islandora 7.x













EOF

echo -e "\n\n\n+---------------------------------------------------------------------------------------------------+"
echo "Date: $TODAY                     Host:$HOST"
echo -e "+---------------------------------------------------------------------------------------------------+\n\n"

# Check if xmllint is installed and install if not.
command -v xmllint >/dev/null 2>&1 || { echo -e >&2 "\n\n\n\tI require xmllint but libxml2-utils is not installed.\n\n\n\tDo you wish to install this program?\n";
  select yn in "Yes" "No"; do
    case $yn in
      Yes ) echo "installing...."
        sudo apt-get install -y --force-yes libxml2-utils 2>&1
        break ;;
      No ) exit ;;
    esac
  done
}

command -v xmllint >/dev/null 2>&1 || { echo -e >&2 "\n\txmllint install failed. Aborting.\n\n\n\n"; exit 1;}

# Auto correct common mistakes.
# ------------------------------------------------------------------------------

# Check if there's anything to process.
if [[ $(find automated_ingesting/2_ready_for_processing -type d -empty) ]]; then
  echo -e "\n\n\n\nDirectory Empty\n\tnothing to process.\n\n\n\n"
  exit
elif [ -f automated_ingesting/2_ready_for_processing/*.* ]; then
  echo -e "woops, extra files in read to process folder.\n\n$(ls automated_ingesting/2_ready_for_processing/*.*)" >> ${three_errors}/problems_with_start.txt
  exit
fi

if [[ ! -d ${CURRENT_DIR}/collection_templates ]]; then
  echo "YAML templates are missing."
  exit
fi

# Cleanup incase of an OSX or Windows mounts create hidden files.
find . -type f -name '*.DS_Store' -ls -delete
find . -type f -name 'Thumbs.db' -ls -delete

# Rename tiff to tif
find . -name "*.tiff" -exec bash -c 'mv "$1" "${1%.tiff}".tif' - '{}' \;
# END of correct common mistakes.

# code snippet from
# https://github.com/unc-charlotte-libraries/islandora_ingest_dragndrop
system_ready=$(ps aux 2>/dev/null |grep islandora_batch_ingest 2>/dev/null |wc -l)
if (( $system_ready == '0' || $system_ready == '1')); then
  sleep 5
  # Loop through the collections
  # ------------------------------------------------------------------------------
  for FOLDER in automated_ingesting/2_ready_for_processing/*; do
    # reset errors log file.
    rm -f ${three_errors}/$(basename ${FOLDER}).txt

    # Check everything first.
    # ----------------------------------------------------------------------------

    # Empty directory found alert.
    if [[ $(find $FOLDER -type d -empty) ]]; then
      echo "Found an empty directory."
      echo -e "Found an empty directory \n\t$(find $FOLDER -type d -empty)\n" >> ${three_errors}/$(basename ${FOLDER}).txt
    fi

    # Empty file found alert.
    if [[ -n $(find $FOLDER -type f -empty) ]]; then
      echo "Found an empty file."
      echo -e "Found an empty file \n\t$(find $FOLDER -type f -empty)\n" >> ${three_errors}/$(basename ${FOLDER}).txt
    fi

    if [[ -d $FOLDER/book ]]; then

      # Correct if filename for MODS/PDF is lowercase or the extension is uppercase.
      rename --force 's/\.([^.]+)$/.\L$1/' $FOLDER/*/*/*.*
      rename --force 's/([^.]*)/\U$1/' $FOLDER/*/*/*.*

      # Correct if filename for OBJ/OCR is lowercase or the extension is uppercase.
      rename --force 's/\.([^.]+)$/.\L$1/' $FOLDER/*/*/*/*.*
      rename --force 's/([^.]*)/\U$1/' $FOLDER/*/*/*/*.*

      # Look for unexpected files inside of the ready_to_process folder
      EXTRA_FILES_FOUND=$(find $FOLDER/* -maxdepth 0 -name \* -and -type f | wc -l)

      # Look for unexpected files inside of the collection folder.
      EXTRA_FILES_FOUND=$(( $EXTRA_FILES_FOUND + $(find $FOLDER/*/* -maxdepth 0 -name \* ! -iname "*.yml" -and -type f | wc -l)))

      if [[ $EXTRA_FILES_FOUND > 0 ]]; then
        # If extra files were found echo a message to a file by the collection name in the errors folder.
        [[ ! -e ${three_errors}/$(basename ${FOLDER}).txt ]] && touch ${three_errors}/$(basename ${FOLDER}).txt
        echo -e "${EXTRA_FILES_FOUND} Extra files found in $(basename ${FOLDER})" >> ${three_errors}/$(basename ${FOLDER}).txt
      fi

      # Verify the folder's naming convention matches the content model names.
      for SUBFOLDER in $FOLDER/*; do
        case "$(basename $SUBFOLDER)" in
          "book" )
            ;;
          "large_image" )
            ;;
          "basic" )
            ;;
          * )
            echo "FOUND ${SUBFOLDER} folder by the wrong name in $FOLDER" >> ${three_errors}/$(basename ${FOLDER}).txt
            ;;
        esac
      done # End of SUBFOLDER loop

      # Create MODS and validate.
      cd ${WORKING_HOME_DIR}
      for YML_FILE in $FOLDER/*/*.yml; do
        if [[ $(/bin/bash ${CURRENT_DIR}/check_yaml.sh $YML_FILE) == "fail" ]];  then
          echo -e >&2 "\n\n\n\tYAML file didn't pass checks. Empty value detected.\n\n\n" >> "${three_errors}/$(basename ${FOLDER}).txt"
        fi
        /bin/bash ${CURRENT_DIR}/create_mods.sh "${WORKING_HOME_DIR}/${YML_FILE%.yml}" "${FOLDER}" "${WORKING_HOME_DIR}"
      done
      # Create the DC files for each page directory.
      COUNTER=0
      for PAGE_FOLDER in $FOLDER/*/*/*/; do

        count_obj_in_folder=(`find $PAGE_FOLDER -maxdepth 1 -name "*.tif"`)
        count_obj_in_folder+=(`find $PAGE_FOLDER -maxdepth 1 -name "*.jp2"`)
        if [ ${#count_obj_in_folder[@]} -gt 1 ]; then
          echo "There are ${#count_obj_in_folder[@]} number of images in the ${PAGE_FOLDER} folder. Please remove one."  >> ${three_errors}/$(basename ${FOLDER}).txt
        else
          if [ ! -f "${PAGE_FOLDER}/OBJ.tif" ] && [ $(find $PAGE_FOLDER -maxdepth 1 -name "*.tif" | wc -l) -gt 0 ]; then
            mv $PAGE_FOLDER/*.tif $PAGE_FOLDER/OBJ.tif
          fi
          if [ ! -f "$PAGE_FOLDER/*.jp2" ] && [ $(find $PAGE_FOLDER -maxdepth 1 -name "*.jp2" | wc -l) -gt 0 ]; then
            mv $PAGE_FOLDER/*.jp2 $PAGE_FOLDER/OBJ.jp2
          fi
        fi
        unset count_obj_in_folder

        /bin/bash ${CURRENT_DIR}/create_dc.sh "${WORKING_HOME_DIR}/${PAGE_FOLDER}" "${CURRENT_DIR}/${FOLDER}" "${WORKING_HOME_DIR}"
        let COUNTER=COUNTER+1
        echo "Counter = $COUNTER"
        sleep $seconds_to_slowdown_validation
        if [[ $COUNTER -gt 30 ]]; then
          sleep $seconds_for_a_pause_validation
          let COUNTER=0
        fi

      done
      cd -
      # Page level directory checks.
      # ----------------------------------------------------------------------------
      for PAGE_FOLDER in $FOLDER/*/*/*; do
        # Page level folders should only be numeric.
        if [[ ! $(basename $PAGE_FOLDER) =~ ^[0-9]+$ ]]; then
          # Checking the the files in this Folder match the expected Naming convention.
          case "$(basename $PAGE_FOLDER)" in
            "MODS.xml" )
              ;;
            "PDF.pdf" )
              ;;
            "ORIGINAL.pdf" )
              ;;
            "ORIGINAL_EDITED.pdf" )
              ;;
            * )
              echo -e "**** FOUND a file that shouldn't be here. **** \n"
              echo -e "$PAGE_FOLDER: not recognised" >> ${three_errors}/$(basename ${FOLDER}).txt
              ;;
          esac
        fi
      done # end of for PAGE_FOLDER loop
    fi

    # Check if folder is named correctly.
    if [[ ! "$FOLDER" == *"__"* ]]; then
      basename_for_folder="$(basename $FOLDER)"
      echo "Folder names is incorrect, renaming it."
      mv "${FOLDER}" "${FOLDER/$basename_for_folder/}${basename_for_folder/_/__}"
      FOLDER="${FOLDER/$basename_for_folder/}${basename_for_folder/_/__}"
    fi

    # Only directories (no files) are expected in the collection level folder.
    # Any files here will cause a failure. Checking to verify only directories.
    if [ ! -d "$FOLDER" ]; then
      echo -e "\tFile found in collection folder!\n\t$FOLDER" >> ${three_errors}/${FOLDER}.txt
    fi
  done

  # Loop through collection (Parent Islandora__PID)
  # ------------------------------------------------------------------------------
  for collection in automated_ingesting/2_ready_for_processing/*/; do
    unset msg
    basename_of_collection=$(basename ${collection})
    # clean out old files
    echo "" > /tmp/automated_ingestion.log

    ADMIN_FAILURES=0
    FAILURES=0
    MESSAGES=""

    # Exit if errors in filesystem exist.
    if [ -s ${three_errors}/$(basename ${collection}).txt ]; then
      echo -e "\tError log is not empty and directory requires attention.\n\n"

      # move collection to error folder.
      [[ $TEST_RUN == true ]] || mv "${collection}" "${three_errors}/"
      exit

    else
      echo -e "\n\n\n\tGeneral Checks complete without any errors.\n\n"

      # Check that the PID exist
      # --------------------------------------------------------------------------

      status_code=$(curl --write-out %{http_code} --silent --output /dev/null "http://localhost:8000/islandora/object/${basename_of_collection/__/%3A}")
      if [[ "$status_code" -eq 200 ]] ; then
        # ------------------------------------------------------------------------
        # Book processing
        # ------------------------------------------------------------------------
        if [[ -d ${collection}book ]]; then
          if [ "$(ls -A ${collection}book)" ]; then

            # Are the page folders sequential.
            # --------------------------------------------------------------------
            folders=(${collection}book/*/*)
            IFS=$'\n' sorted=($(sort <<<"${folders[*]}"))
            unset IFS

            for ix in ${!folders[*]}; do
              if [[ -d "${folders[$ix]}" ]]; then
                NUM="$(basename ${folders[$ix]})"
                NUM="$(expr $NUM + 1)"

                # Compare only if the next item is a directory.
                if [[ -d "${folders[$(($ix+1))]%[*}" ]]; then
                  if [[ "$(basename ${folders[$(($ix+1))]%[*})" == ?(-)+([0-9]) ]] ; then
                    NUMTWO="$(expr $(basename ${folders[$(($ix+1))]%[*}) + 0)"
                    if [[ ! $NUM -eq $NUMTWO ]]; then
                      echo "PAGE directories are not sequential. ${folders[$ix]}" >> ${three_errors}/$basename_of_collection.txt
                      [[ $TEST_RUN == true ]] || mv "${collection}" "${three_errors}/"
                      exit
                    fi
                  fi
                fi
              fi
            done

            namespace="${basename_of_collection#*__}"
            # If no drupal directory was found exit.
            [[ -d $DRUPAL_HOME_DIR ]] || exit

            # Ingest book
            # --------------------------------------------------------------------
            if [[ ! $TEST_RUN == true ]]; then

              echo "" >> /tmp/automated_ingestion.log
              book_parent="${basename_of_collection//__/:}"

              for D in ${collection}book/*/; do
                target="/tmp/$(basename $FOLDER)_$(basename $D)"
                mkdir -p "/tmp/$(basename $FOLDER)_$(basename $D)/issue1/"
                let WORKING_TMP=1
                WORKING_TMP_DIR="/tmp/$(basename $FOLDER)_$(basename $D)/issue1/"

                rsync -avz "${WORKING_HOME_DIR}/${D}" "/tmp/$(basename $FOLDER)_$(basename $D)/issue1/"
                if [ "$?" -eq "0" ]; then
                  echo "Done"
                else
                  echo "Error while running copying files from ${WORKING_HOME_DIR}/${D} to /tmp/$(basename $FOLDER)_$(basename $D)/issue1/" >> ${three_errors}/$(basename ${collection}).txt
                  exit
                fi

                INGESTION_STARTED="${collection}"

                # Book queuing for ingestion.
                $($DRUSH -v --root=/var/www/drupal -u 1 --uri=http://localhost islandora_book_batch_preprocess --parent=$book_parent --namespace=$namespace --type=directory --target=$target --output_set_id=TRUE >> /tmp/automated_ingestion.log)

                # removes blank lines
                sed -i '/^$/d' /tmp/automated_ingestion.log

                sid_value=$(cat /tmp/automated_ingestion.log | head -1 | tail -1)

                # Ingesting book
                $($DRUSH -v -u 1 --root=/var/www/drupal --uri=http://localhost islandora_batch_ingest >> /tmp/automated_ingestion.log)

                # Locating parent PID.
                QU1="SELECT id FROM islandora_batch_queue WHERE sid=${sid_value} AND parent IS NOT NULL"
                [[ $sid_value ]] && BATCH_PIDS=$($DRUSH -v --root=/var/www/drupal sql-query --db-prefix "${QU1}" | grep "[:]")
                BATCH_PIDS=(${BATCH_PIDS//\\n/ })
                for i in "${BATCH_PIDS[@]}"
                do
                  PAGE_STATUS=$(curl --write-out %{http_code} --silent --output /dev/null "http://localhost:8000/islandora/object/${i}/datastream/OBJ/view")
                  [ ! $PAGE_STATUS == 200 ] && echo "PAGE PID ${i} came back with a status code of ${PAGE_STATUS}" >> ${three_errors}/$(basename ${collection}).txt
                done
                unset target
                rm -rf "/tmp/$(basename $FOLDER)_$(basename $D)"
                let WORKING_TMP=0
                WORKING_TMP_DIR=""
                let INGESTION_STARTED=0
              done

              # Known False alarms
              sed '/java.io.FileNotFoundException:/d' /tmp/automated_ingestion.log > /tmp/automated_ingestion.log

              msg=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Failed to ingest object.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Exception:.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Unknown options:.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep '\[error\]')

              if [[ $msg ]]; then
                echo -e "We have an error with the ingestion process\n\n$msg" >> ${three_errors}/$(basename ${collection}).txt
                let FAILURES=FAILURES+1
              else
                echo -e "\tSuccess!\n\t\tBook objects ingested\n\n"
                echo "PID: ${sid_value}"
              fi
              unset msg
              rm -f /tmp/automated_ingestion.log
            fi
          fi
        fi

        # ------------------------------------------------------------------------
        # Basic Image processing
        # ------------------------------------------------------------------------
        sleep 5
        if [[ -d ${collection}basic ]]; then
          if [ "$(ls -A ${collection}basic)" ]; then

            basic_img_namespace="${basename_of_collection#*__}"
            basic_img_target="${WORKING_HOME_DIR}/${collection}basic"
            basic_img_parent="${basename_of_collection//__/:}"

            # Find and correct spaces in the filename.
            find $basic_img_target -type f -name "* *" | while read file; do mv "$file" ${file// /}; done

            # Check images have pairs
            echo "start ${collection}basic"
            basic_img_file_count=$(ls ${collection}basic | egrep '\.png$|\.jpg$|\.bmp$|\.gif$' | wc -l)
            basic_img_mods_count=$(ls ${collection}basic | egrep '\.xml$' | wc -l)

            # Check that the number of MODS equals the number of images.
            if [[ ! $basic_img_file_count == $basic_img_mods_count ]]; then
              echo -e "\n\tImages & MODS don't have exact matches Images:$basic_img_file_count MODS:$basic_img_mods_count\n\t\tEither missing or too many MODS files." >> ${three_errors}/$(basename ${collection}).txt
            fi

            # Check that each image has a matching MODS file by the same name.
            for basic_image_file in $(ls ${collection}basic | egrep '\.png$|\.jpg$|\.bmp$|\.gif$'); do
              if [[ ! -f "${collection}basic/${basic_image_file%.*}.xml" ]]; then
                echo -e "\t\t${basic_image_file%.*}.xml MODS file is missing for ${basic_image_file}" >> ${three_errors}/$(basename ${collection}).txt
              fi
            done

            # If no drupal directory was found exit.
            [[ -d $DRUPAL_HOME_DIR ]] || exit

            # Basic image ingest content
            # --------------------------------------------------------------------
            if [[ ! $TEST_RUN == true ]]; then
              echo "" > /tmp/automated_ingestion.log
              echo "Basic -----> $basic_img_parent"
              INGESTION_STARTED="${collection}"
              # Basic Image queuing for ingestion.
              $($DRUSH -v --root=/var/www/drupal -u 1 --uri=http://localhost islandora_batch_scan_preprocess --content_models=islandora:sp_basic_image --parent=$basic_img_parent --type=directory --target=$basic_img_target && $DRUSH -v -u 1 --root=/var/www/drupal --uri=http://localhost islandora_batch_ingest >> /tmp/automated_ingestion.log)

              msg=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Failed to ingest object.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Exception:.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Unknown options:.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep '\[error\]')

              if [[ $msg ]]; then
                echo -e "We have an error with the ingestion process" >> ${three_errors}/$(basename ${collection}).txt
                let FAILURES=FAILURES+1
              else
                echo "Success!"
                echo -e "Basic Image objects ingested\n\n"
                let INGESTION_STARTED=0
              fi
              unset msg
            fi
          fi
        fi
        # ------------------------------------------------------------------------
        # Large Image processing.
        # ------------------------------------------------------------------------
        sleep 5
        if [[ -d ${collection}large_image ]]; then
          if [ "$(ls -A ${collection}large_image)" ]; then
            large_image_namespace="${basename_of_collection#*__}"
            large_image_target="${WORKING_HOME_DIR}/${collection}large_image/"
            large_image_parent="${basename_of_collection//__/:}"

            # Find and correct spaces in the filename.
            find $large_image_target -type f -name "* *" | while read file; do mv "$file" ${file// /}; done

            # Check Large images have pairs
            large_image_file_count=$(ls ${collection}large_image | egrep '\.tif$|\.jp2$' | wc -l)
            large_image_mods_count=$(ls ${collection}large_image | egrep '\.xml$' | wc -l)

            if [[ ! $large_image_file_count == $large_image_mods_count ]]; then
              echo -e "\n\tImages & MODS don't have exact matches Images:$large_image_file_count MODS:$large_image_mods_count\n\t\tEither missing or too many MODS files." >> ${three_errors}/$(basename ${collection}).txt
            fi

            for large_image_file in $(ls ${collection}large_image | egrep '\.tif$|\.jp2$'); do
              if [[ ! -f "${collection}large_image/${large_image_file%.*}.xml" ]]; then
                echo -e "\t\t${large_image_file%.*}.xml MODS file is missing for ${large_image_file}" >> ${three_errors}/$(basename ${collection}).txt
              fi
            done

            # If no drupal directory was found exit.
            [[ -d $DRUPAL_HOME_DIR ]] || exit

            # Large image ingest content.
            # --------------------------------------------------------------------
            if [[ ! $TEST_RUN == true ]]; then
              echo "" > /tmp/automated_ingestion.log
              INGESTION_STARTED="${collection}"
              # Large Image queuing for ingestion.
              $($DRUSH -v --root=/var/www/drupal -u 1 --uri=http://localhost  islandora_batch_scan_preprocess --content_models=islandora:sp_large_image_cmodel --parent=$large_image_parent --type=directory --target=$large_image_target && $DRUSH -v -u 1 --root=/var/www/drupal --uri=http://localhost islandora_batch_ingest >> /tmp/automated_ingestion.log)

              msg=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Failed to ingest object.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Exception:.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep -Pzo '^.*?Unknown options:.*?(\n(?=\s).*?)*$')
              msg+=$(cat /tmp/automated_ingestion.log | grep '\[error\]')

              if [[ $msg ]]; then
                echo -e "We have an error with the ingestion process" >> ${three_errors}/$(basename ${collection}).txt
                let FAILURES=FAILURES+1
              else
                echo "Success!"
                echo -e "Basic Image objects ingested\n\n"
              fi
              let INGESTION_STARTED=0
            fi
          fi
        fi

      else
        MESSAGES += "PID unknown for $collection"
        let FAILURES=FAILURES+1
      fi

      # Actions for when a Failure is detected
      # --------------------------------------------------------------------------
      if [[ "$FAILURES" -gt 0 ]] || [[ "$ADMIN_FAILURES" -gt 0 ]]; then
        echo -e "\n\n\nFailure detected with ${collection}\n\t${FAILURES}\n\n"

        # Set the location where the error folder is.
        ERROR_LOCATION="${three_errors}/"

        # Check to see if there's a naming conflict for error directory.
        if [[ -d "${three_errors}/${basename_of_collection}" ]]; then
          ERROR_LOCATION="${three_errors}/${basename_of_collection}_NAME_CONFLICT_$(date +%N)"
        fi

        # Move to error folder.
        [[ $TEST_RUN == true ]] || mv "${collection}" "${ERROR_LOCATION}"

        # Check if the error occurred after the ingestion process started.
        if [[ $ADMIN_FAILURES -eq 1 ]]; then
          # Send a warning to the log file that a SYSTEMS ADMIN is needed to correct this error and not to reattempt.
          echo -e "PLEASE CONTACT SYSTEM ADMIN.\n\tDo NOT attempt to reprocess the $(basename ${collection}) directory. This directory is set to read only until system admin has corrected the issue.\n${MESSAGES}" >> ${three_errors}/$(basename ${collection}).txt
        else
          echo -e "${MESSAGES}" >> ${three_errors}/$(basename ${collection}).txt
        fi

      else
        echo -e "Everything Completed.\n\n\tMoving files to 'completed' directory."

        # Check to see if there's a naming conflict for completed directory.
        if [[ -d "${four_completed}/${basename_of_collection}" ]]; then
          [[ $TEST_RUN == true ]] || mv "${collection}" "${four_completed}/${basename_of_collection}_NAME_CONFLICT_$(date +%N)"
        else
          [[ $TEST_RUN == true ]] || mv "${collection}" "${four_completed}/"
        fi

        echo -e "\tMove Complete.\n\n"
      fi

    fi # End/Else of error log check
  done # End of for collection

  # Cleanup
  cleanup_files
else
  echo "Another ingest is running. Aborting."
fi

TODAY=$(date)
HOST=$(hostname)
echo -e "\n\n\n+---------------------------------------------------------------------------------------------------+"
echo "Date: $TODAY                     Host:$HOST"
echo -e "+---------------------------------------------------------------------------------------------------+ \n\n\n\n\n"
