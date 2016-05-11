set -e

if which toxiproxy > /dev/null; then
  echo "Toxiproxy is already installed."
  exit 0
fi

if which apt-get > /dev/null; then
  echo "Installing toxiproxy"
  wget -O /tmp/toxiproxy.deb https://github.com/Shopify/toxiproxy/releases/download/v2.0.0/toxiproxy_2.0.0_amd64.deb
  sudo dpkg -i /tmp/toxiproxy.deb
  sudo service toxiproxy start
  exit 0
fi

if which brew > /dev/null; then
  echo "Installing toxiproxy from homebrew."
  brew tap shopify/shopify
  brew install toxiproxy
  brew info toxiproxy
  exit 0
fi

echo "Sorry, there is no toxiproxy package available for your system. You might need to build it from source."
exit 1
