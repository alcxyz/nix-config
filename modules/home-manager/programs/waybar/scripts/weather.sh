#!/usr/bin/env bash

# Simple weather script - customize as needed
LOCATION="London"  # Change to your location
API_KEY=""  # Add your OpenWeatherMap API key if desired

if [ -n "$API_KEY" ]; then
    # Using OpenWeatherMap API (requires API key)
    WEATHER=$(curl -s "http://api.openweathermap.org/data/2.5/weather?q=$LOCATION&appid=$API_KEY&units=metric" | jq -r '.main.temp')
    echo "{\"text\": \"🌤 ${WEATHER}°C\", \"tooltip\": \"Weather in $LOCATION\"}"
else
    # Fallback without API
    echo "{\"text\": \"🌤\", \"tooltip\": \"Weather widget\"}"
fi
