#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Enhanced error handling
set -eE
trap 'handle_error $? $LINENO $BASH_LINENO "$BASH_COMMAND" $(printf "::%s" ${FUNCNAME[@]:-})' ERR

handle_error() {
    local exit_code=$1
    local line_no=$2
    local bash_lineno=$3
    local last_command=$4
    local error_trap=$5
    echo -e "\n${RED}Error occurred in script at line: $line_no${NC}"
    echo -e "${RED}Command: $last_command${NC}"
    echo -e "${RED}Exit code: $exit_code${NC}"
    cleanup_on_error
}

cleanup_on_error() {
    echo -e "\n${YELLOW}Cleaning up failed installation...${NC}"
    systemctl stop computer-assistant 2>/dev/null || true
    systemctl disable computer-assistant 2>/dev/null || true
    rm -f /etc/systemd/system/computer-assistant.service 2>/dev/null || true
    rm -f /usr/share/applications/computer-assistant.desktop 2>/dev/null || true
    echo -e "${YELLOW}Cleanup completed. Please check the error message above and try again.${NC}"
    exit 1
}

# Function to check if a command was successful
check_status() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
        return 1
    fi
}

# Function to backup existing configuration
backup_existing() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    if [ -d "/opt/computer-assistant" ]; then
        echo -e "\n${BLUE}Backing up existing installation...${NC}"
        tar -czf "/opt/computer-assistant_backup_$timestamp.tar.gz" /opt/computer-assistant 2>/dev/null
        rm -rf /opt/computer-assistant
        check_status
    fi
}

# Function to test dependencies
test_dependencies() {
    local missing_deps=()
    local deps=("python3" "pip" "node" "npm" "aplay" "amixer" "ffmpeg")
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            missing_deps+=($dep)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing_deps[*]}${NC}"
        return 1
    fi
    return 0
}

echo -e "${BLUE}=== Computer Voice Assistant Installation Script for Linux Mint ===${NC}"
echo -e "${BLUE}=== Version 2.0 ===${NC}"

# Check if script is run with sudo
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run with sudo privileges${NC}"
    exit 1
fi

# Check system compatibility
echo -e "\n${BLUE}Checking system compatibility...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "linuxmint" ]]; then
        echo -e "${GREEN}✓ Linux Mint detected${NC}"
    else
        echo -e "${YELLOW}Warning: This script is optimized for Linux Mint but will attempt to continue${NC}"
    fi
fi

# Backup existing installation
backup_existing

# Install system dependencies
echo -e "\n${BLUE}Installing system dependencies...${NC}"
echo -e "${YELLOW}Updating package lists...${NC}"
apt-get update

echo -e "${YELLOW}Installing required packages...${NC}"
for package in python3-pip python3-venv portaudio19-dev python3-dev python3-pyaudio ffmpeg xdotool wmctrl alsa-utils pulseaudio pulseaudio-utils git nodejs npm libnotify-bin; do
    echo -e "${BLUE}Installing $package...${NC}"
    apt-get install -y $package
    check_status
done

# Test dependencies
echo -e "\n${BLUE}Verifying dependencies...${NC}"
test_dependencies
check_status

# Create installation directory with versioning
INSTALL_DIR="/opt/computer-assistant"
VERSION="2.0.0"
mkdir -p $INSTALL_DIR
echo $VERSION > $INSTALL_DIR/version.txt

# Create Python virtual environment
echo -e "\n${BLUE}Setting up Python virtual environment...${NC}"
python3 -m venv $INSTALL_DIR/venv
source $INSTALL_DIR/venv/bin/activate
check_status

# Install Python packages individually with progress
echo -e "\n${BLUE}Installing Python packages...${NC}"
echo -e "${YELLOW}Upgrading pip...${NC}"
pip install --upgrade pip

python_packages=(
    "SpeechRecognition"
    "PyAudio"
    "gTTS"
    "pygame"
    "numpy"
    "psutil"
    "rich"
    "pyyaml"
    "pynput"
    "pyautogui"
    "python-xlib"
    "requests"
    "pydbus"
    "notify2"
)

for package in "${python_packages[@]}"; do
    echo -e "${BLUE}Installing $package...${NC}"
    pip install "$package"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully installed $package${NC}"
    else
        echo -e "${RED}✗ Failed to install $package${NC}"
        exit 1
    fi
done

# Create enhanced backend script
echo -e "\n${BLUE}Creating enhanced backend service...${NC}"
cat > $INSTALL_DIR/computer_service.py << 'EOL'
#!/usr/bin/env python3

import os
import sys
import time
import threading
import logging
import speech_recognition as sr
from gtts import gTTS
import pygame
import json
import yaml
from datetime import datetime
import pyautogui
import subprocess
import notify2
from rich.console import Console
from rich.panel import Panel
from rich.live import Live
from rich.table import Table
import requests
import psutil
import re

class ComputerAssistant:
    def __init__(self):
        self.console = Console()
        self.recognizer = sr.Recognizer()
        pygame.mixer.init()
        self.is_running = True
        self.setup_logging()
        self.load_config()
        notify2.init('Computer Assistant')
        self.notification = notify2.Notification('Computer Assistant')
        
    def setup_logging(self):
        log_dir = os.path.join(os.path.dirname(__file__), 'logs')
        os.makedirs(log_dir, exist_ok=True)
        log_file = os.path.join(log_dir, f'assistant_{datetime.now().strftime("%Y%m%d")}.log')
        
        logging.basicConfig(
            filename=log_file,
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s'
        )

    def load_config(self):
        config_file = os.path.join(os.path.dirname(__file__), 'config.yml')
        default_config = {
            'voice': 'en',
            'volume': 1.0,
            'custom_commands': {}
        }
        
        if os.path.exists(config_file):
            with open(config_file, 'r') as f:
                self.config = yaml.safe_load(f) or default_config
        else:
            self.config = default_config
            with open(config_file, 'w') as f:
                yaml.dump(default_config, f)

    def notify(self, title, message):
        self.notification.update(title, message)
        self.notification.show()

    def speak(self, text):
        try:
            tts = gTTS(text=text, lang=self.config['voice'])
            temp_file = "/tmp/temp_speech.mp3"
            tts.save(temp_file)
            
            pygame.mixer.music.load(temp_file)
            pygame.mixer.music.set_volume(self.config['volume'])
            pygame.mixer.music.play()
            while pygame.mixer.music.get_busy():
                pygame.time.Clock().tick(10)
            
            os.remove(temp_file)
            logging.info(f"Spoke: {text}")
            self.notify("Computer Assistant", text)
        except Exception as e:
            logging.error(f"Speech error: {e}")

    def execute_command(self, command):
        try:
            # Custom commands
            if command in self.config['custom_commands']:
                cmd = self.config['custom_commands'][command]
                subprocess.Popen(cmd.split())
                return f"Executed custom command: {command}"

            # System commands
            if "open" in command:
                app = command.split("open")[-1].strip()
                subprocess.Popen([app])
                return f"Opening {app}"
                
            elif "type" in command:
                text = command.split("type")[-1].strip()
                pyautogui.write(text)
                return f"Typed: {text}"
                
            elif "click" in command:
                pyautogui.click()
                return "Clicked"
                
            elif "volume" in command:
                if "up" in command:
                    subprocess.run(["amixer", "-D", "pulse", "sset", "Master", "10%+"])
                    return "Volume increased"
                elif "down" in command:
                    subprocess.run(["amixer", "-D", "pulse", "sset", "Master", "10%-"])
                    return "Volume decreased"
                elif "mute" in command:
                    subprocess.run(["amixer", "-D", "pulse", "sset", "Master", "0%"])
                    return "Volume muted"
                    
            elif "brightness" in command:
                if "up" in command:
                    subprocess.run(["xbacklight", "-inc", "10"])
                    return "Brightness increased"
                elif "down" in command:
                    subprocess.run(["xbacklight", "-dec", "10"])
                    return "Brightness decreased"
                    
            elif "system" in command:
                if "status" in command:
                    cpu = psutil.cpu_percent()
                    mem = psutil.virtual_memory().percent
                    return f"CPU usage: {cpu}%, Memory usage: {mem}%"
                elif "shutdown" in command:
                    subprocess.run(["shutdown", "-h", "now"])
                    return "Shutting down system"
                elif "restart" in command:
                    subprocess.run(["shutdown", "-r", "now"])
                    return "Restarting system"
                    
            elif "weather" in command:
                return "Weather feature requires API configuration"
                
            elif "stop" in command or "exit" in command:
                self.is_running = False
                return "Stopping assistant"
                
            return f"Command not recognized: {command}"
            
        except Exception as e:
            logging.error(f"Command execution error: {e}")
            return f"Error executing command: {str(e)}"

    def run(self):
        self.console.print(Panel.fit("Computer Voice Assistant Active"))
        self.speak("Computer assistant is ready")
        
        with sr.Microphone() as source:
            self.recognizer.adjust_for_ambient_noise(source)
            
            while self.is_running:
                try:
                    audio = self.recognizer.listen(source, timeout=1, phrase_time_limit=5)
                    text = self.recognizer.recognize_google(audio).lower()
                    
                    if text.startswith("computer"):
                        command = text.replace("computer", "", 1).strip()
                        response = self.execute_command(command)
                        self.speak(response)
                        self.console.print(f"Command: {command}")
                        self.console.print(f"Response: {response}")
                        logging.info(f"Executed command: {command} - Response: {response}")
                        
                except sr.WaitTimeoutError:
                    continue
                except sr.UnknownValueError:
                    continue
                except Exception as e:
                    logging.error(f"Error: {e}")
                    
if __name__ == "__main__":
    assistant = ComputerAssistant()
    assistant.run()
EOL

chmod +x $INSTALL_DIR/computer_service.py
check_status

# Create default configuration
echo -e "\n${BLUE}Creating default configuration...${NC}"
cat > $INSTALL_DIR/config.yml << EOL
voice: 'en'
volume: 1.0
custom_commands:
  'launch browser': 'firefox'
  'open terminal': 'gnome-terminal'
  'show files': 'nemo'
EOL
check_status

# Create systemd service with enhanced options
echo -e "\n${BLUE}Creating systemd service...${NC}"
cat > /etc/systemd/system/computer-assistant.service << EOL
[Unit]
Description=Computer Voice Assistant
After=network.target pulseaudio.service
Wants=pulseaudio.service

[Service]
Type=simple
User=$SUDO_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$SUDO_USER/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $SUDO_USER)
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/computer_service.py
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=3
Nice=-5

[Install]
WantedBy=multi-user.target
EOL
check_status

# Create enhanced desktop entry
echo -e "\n${BLUE}Creating desktop entry...${NC}"
cat > /usr/share/applications/computer-assistant.desktop << EOL
[Desktop Entry]
Name=Computer Assistant
Comment=Voice Control Assistant
Exec=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/computer_service.py
Icon=microphone-sensitivity-high
Terminal=true
Type=Application
Categories=Utility;
Keywords=voice;assistant;computer;control;
StartupNotify=true
EOL
check_status

# Create autostart entry
echo -e "\n${BLUE}Setting up autostart...${NC}"
mkdir -p /home/$SUDO_USER/.config/autostart
cp /usr/share/applications/computer-assistant.desktop /home/$SUDO_USER/.config/autostart/
check_status

# Set up audio monitoring and auto-recovery
echo -e "\n${BLUE}Setting up audio monitoring...${NC}"
cat > $INSTALL_DIR/audio_monitor.sh << 'EOL'
#!/bin/bash
while true; do
    if ! pulseaudio --check; then
        pulseaudio --start
        notify-send "Computer Assistant" "Audio service restored"
    fi
    sleep 30
done
EOL
chmod +x $INSTALL_DIR/audio_monitor.sh
check_status

# Set permissions
echo -e "\n${BLUE}Setting permissions...${NC}"
chown -R $SUDO_USER:$SUDO_USER $INSTALL_DIR
chmod -R 755 $INSTALL_DIR
check_status

# Enable and start services
echo -e "\n${BLUE}Starting services...${NC}"
systemctl daemon-reload
systemctl enable computer-assistant
systemctl start computer-assistant
check_status

# Verify installation
echo -e "\n${BLUE}Verifying installation...${NC}"
if systemctl is-active --quiet computer-assistant; then
    echo -e "${GREEN}Service is running${NC}"
else
    echo -e "${RED}Service failed to start${NC}"
    journalctl -u computer-assistant -n 50
    exit 1
fi

# Verify installation
echo -e "\n${BLUE}Verifying installation...${NC}"
if systemctl is-active --quiet computer-assistant; then
    echo -e "${GREEN}Service is running${NC}"
else
    echo -e "${RED}Service failed to start${NC}"
    journalctl -u computer-assistant -n 50
    exit 1
fi

# Enhanced audio system testing
echo -e "\n${BLUE}Testing audio system...${NC}"

# Ensure pulseaudio is running
echo -e "${YELLOW}Checking PulseAudio status...${NC}"
if ! pulseaudio --check; then
    echo -e "${YELLOW}Starting PulseAudio...${NC}"
    sudo -u $SUDO_USER pulseaudio --start
    sleep 2
fi

# Test audio setup
echo -e "${YELLOW}Configuring audio...${NC}"
if command -v amixer > /dev/null; then
    # Try different audio configurations
    amixer set Master unmute 2>/dev/null || true
    amixer set Speaker unmute 2>/dev/null || true
    amixer set Headphone unmute 2>/dev/null || true
    
    # Set a reasonable default volume
    amixer set Master 70% 2>/dev/null || true
    
    echo -e "${GREEN}✓ Basic audio configuration completed${NC}"
else
    echo -e "${YELLOW}Warning: amixer not found, skipping audio configuration${NC}"
fi

# Verify audio devices
if command -v aplay > /dev/null; then
    echo -e "${YELLOW}Checking audio devices...${NC}"
    AUDIO_DEVICES=$(aplay -l 2>/dev/null || true)
    if [ ! -z "$AUDIO_DEVICES" ]; then
        echo -e "${GREEN}✓ Audio devices found:${NC}"
        echo "$AUDIO_DEVICES"
    else
        echo -e "${YELLOW}Warning: No audio devices detected${NC}"
    fi
else
    echo -e "${YELLOW}Warning: aplay not found, cannot check audio devices${NC}"
fi

# Final setup message
echo -e "\n${GREEN}=== Installation Complete! ===${NC}"
echo -e "\nComputer Assistant is now installed and configured."
echo -e "\nTo test the assistant:"
echo -e "1. Run from terminal: ${BLUE}computer-assistant${NC}"
echo -e "2. Or find 'Computer Assistant' in your applications menu"
echo -e "\nBasic commands (prefix with 'Computer'):"
echo -e "- 'open firefox'"
echo -e "- 'volume up'"
echo -e "- 'volume down'"
echo -e "- 'type hello'"
echo -e "- 'click'"
echo -e "- 'system status'"
echo -e "- 'stop'"

# Add audio troubleshooting information
echo -e "\n${YELLOW}If you experience audio issues:${NC}"
echo -e "1. Run: ${BLUE}pavucontrol${NC} to check audio settings"
echo -e "2. Verify microphone permissions in system settings"
echo -e "3. Check logs: ${BLUE}journalctl -u computer-assistant${NC}"
