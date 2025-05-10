#!/bin/bash

# Script to send a file as an attachment to a Discord webhook
# This version takes input via command-line flags

# Check if required tools are installed
if ! command -v curl &> /dev/null
then
    echo "Error: curl is required but not installed. Please install it (e.g., sudo apt install curl)."
    exit 1
fi

# --- Configuration ---
WEBHOOK_URL=""  # Replace with your Discord webhook URL - VERY IMPORTANT
# --- Configuration ---

# --- Input Variables (from flags) ---
FILE_PATH=""
FILENAME="recon.txt"
MESSAGE="File attached:" # Default message

# --- Helper Functions ---

# Function to check if a variable is empty
is_empty() {
  [ -z "$1" ]
}

# Function to check if a file exists
file_exists() {
  [ -f "$1" ]
}

# Function to send the file to Discord
send_file_to_discord() {
  # Input validation
  if is_empty "$WEBHOOK_URL"
  then
    echo "Error: WEBHOOK_URL is not set.  Please edit the script to include your webhook URL."
    return 1
  fi

  if is_empty "$FILE_PATH"
  then
    echo "Error: FILE_PATH is not set.  Use the -f flag to specify the file."
    return 1
  fi

  if ! file_exists "$FILE_PATH"
  then
    echo "Error: File not found at $FILE_PATH"
    return 1
  fi

  # Use a default filename if FILENAME is empty
  if is_empty "$FILENAME"
  then
    FILENAME=$(basename "$FILE_PATH")
  fi

  # Prepare the curl command
  curl_command=(
    curl
    -X POST
    -H "Content-Type: multipart/form-data"
    -F "payload_json={\"content\":\"$MESSAGE\"}"
    -F "file=@$FILE_PATH;filename=$FILENAME"
    "$WEBHOOK_URL"
  )

  # Execute the curl command
  if ! "${curl_command[@]}"
  then
    echo "Error: Failed to send file to Discord."
    return 1
  else
    echo "File sent successfully to Discord."
    return 0
  fi
}

# --- Main Script ---

# Parse command-line flags
while getopts "f:n:m:" opt
do
  case "$opt" in
    f)
      FILE_PATH="$OPTARG"
      ;;
    n)
      FILENAME="$OPTARG"
      ;;
    m)
      MESSAGE="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      echo "Usage: $0 -f <file_path> [-n <filename>] [-m <message>]" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      echo "Usage: $0 -f <file_path> [-n <filename>] [-m <message>]" >&2
      exit 1
      ;;
  esac
done

# Check for the presence of the mandatory -f flag
if is_empty "$FILE_PATH"
then
  echo "Error: You must specify the file path using the -f flag." >&2
  echo "Usage: $0 -f <file_path> [-n <filename>] [-m <message>]" >&2
  exit 1
fi

# Send the file
send_file_to_discord

exit $?
