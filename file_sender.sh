#!/bin/bash

# Script to send a file as an attachment to a Telegram chat using Bot API
# This version takes input via command-line flags

# Check if required tools are installed
if ! command -v curl &> /dev/null
then
    echo "Error: curl is required but not installed. Please install it (e.g., sudo apt install curl)."
    exit 1
fi

# --- Configuration (These can also be passed via flags) ---
TELEGRAM_BOT_TOKEN=""  # Replace with your Telegram Bot API Token (from @BotFather) - VERY IMPORTANT
TELEGRAM_CHAT_ID=""    # Replace with your Telegram Chat ID (your personal ID or group ID) - VERY IMPORTANT
# --- Configuration ---

# --- Input Variables (from flags) ---
FILE_PATH=""
# FILENAME is not strictly needed for Telegram sendDocument as it uses the original filename by default
# unless you specifically rename it with the 'filename' parameter in the form-data.
# For simplicity, we'll let Telegram use the original filename from FILE_PATH.
MESSAGE="File attached:" # Default message (will be the caption for the file)

# --- Helper Functions ---

# Function to check if a variable is empty
is_empty() {
  [ -z "$1" ]
}

# Function to check if a file exists
file_exists() {
  [ -f "$1" ]
}

# Function to send the file to Telegram
send_file_to_telegram() {
  # Input validation
  if is_empty "$TELEGRAM_BOT_TOKEN"
  then
    echo "Error: TELEGRAM_BOT_TOKEN is not set. Please provide it using the -t flag."
    return 1
  fi

  if is_empty "$TELEGRAM_CHAT_ID"
  then
    echo "Error: TELEGRAM_CHAT_ID is not set. Please provide it using the -c flag."
    return 1
  fi

  if is_empty "$FILE_PATH"
  then
    echo "Error: FILE_PATH is not set. Use the -f flag to specify the file."
    return 1
  fi

  if ! file_exists "$FILE_PATH"
  then
    echo "Error: File not found at $FILE_PATH"
    return 1
  fi

  # Determine the base filename for the attachment
  local base_filename=$(basename "$FILE_PATH")

  # Prepare the curl command for sending a document
  # Telegram's sendDocument method includes a 'caption' for the message.
  # The 'parse_mode=MarkdownV2' allows for basic formatting in the caption.
  curl_command=(
    curl -s -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
    -F "chat_id=${TELEGRAM_CHAT_ID}"
    -F "document=@${FILE_PATH}"
    -F "caption=${MESSAGE}"
  )

  # Execute the curl command
  echo "Attempting to send file '$base_filename' to Telegram..."
  if ! "${curl_command[@]}"
  then
    echo "Error: Failed to send file to Telegram."
    return 1
  else
    echo "File sent successfully to Telegram."
    return 0
  fi
}

# --- Main Script ---

# Parse command-line flags
while getopts "f:m:t:c:" opt # Removed 'n' and 'h' flags
do
  case "$opt" in
    f)
      FILE_PATH="$OPTARG"
      ;;
    m)
      MESSAGE="$OPTARG"
      ;;
    t)
      TELEGRAM_BOT_TOKEN="$OPTARG"
      ;;
    c)
      TELEGRAM_CHAT_ID="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      echo "Usage: $0 -f <file_path> [-m <message>] -t <bot_token> -c <chat_id>" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      echo "Usage: $0 -f <file_path> [-m <message>] -t <bot_token> -c <chat_id>" >&2
      exit 1
      ;;
  esac
done

# Check for the presence of mandatory flags
if is_empty "$FILE_PATH" || is_empty "$TELEGRAM_BOT_TOKEN" || is_empty "$TELEGRAM_CHAT_ID"
then
  echo "Error: You must specify FILE_PATH (-f), BOT_TOKEN (-t), and CHAT_ID (-c)." >&2
  echo "Usage: $0 -f <file_path> [-m <message>] -t <bot_token> -c <chat_id>" >&2
  exit 1
fi

# Send the file
send_file_to_telegram

exit $?
