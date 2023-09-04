#!/usr/bin/env bash

set -o errexit
set -o pipefail

CLEANUP=${CLEANUP:-"0"}
NETWORK=${NETWORK:-"localnet"}
OS_PLATFORM=$(uname -s)
OS_ARCH=$(uname -m)
GAIA_PLATFORM=${GAIA_PLATFORM:-"linux_amd64"}

case $NETWORK in
  mainnet)
    echo "Using MAINNET"
    GAIA_VERSION=${GAIA_VERSION:-"v4.2.1"}
    GAIA_GENESIS="https://github.com/cosmos/mainnet/raw/master/genesis.cosmoshub-4.json.gz"
    GAIA_GENESIS_HEIGHT=${GAIA_GENESIS_HEIGHT:-"5200791"}
    GAIA_ADDRESS_BOOK="https://quicksync.io/addrbook.cosmos.json"
  ;;
  testnet)
    echo "Using TESTNET"
    GAIA_VERSION=${GAIA_VERSION:-"v6.0.0"}
    GAIA_GENESIS="https://github.com/cosmos/testnets/raw/master/v7-theta/public-testnet/genesis.json.gz"
    GAIA_GENESIS_HEIGHT=${GAIA_GENESIS_HEIGHT:-"9034670"}
  ;;
  localnet)
    echo "Using LOCALNET"
    GAIA_VERSION=${GAIA_VERSION:-"v7.0.0"}
    GAIA_GENESIS=""
    GAIA_GENESIS_HEIGHT=${GAIA_GENESIS_HEIGHT:-"1"}
    MNEMONIC_1=${MNEMONIC_1:-"guard cream sadness conduct invite crumble clock pudding hole grit liar hotel maid produce squeeze return argue turtle know drive eight casino maze host"}
    MNEMONIC_2=${MNEMONIC_2:-"friend excite rough reopen cover wheel spoon convince island path clean monkey play snow number walnut pull lock shoot hurry dream divide concert discover"}
    MNEMONIC_3=${MNEMONIC_3:-"fuel obscure melt april direct second usual hair leave hobby beef bacon solid drum used law mercy worry fat super must ritual bring faculty"}
    GENESIS_COINS=${GENESIS_COINS:-"1000000000000000stake"}
  ;;
  *)
    echo "Invalid network: $NETWORK"; exit 1;
  ;;
esac

case $OS_PLATFORM-$OS_ARCH in
  Darwin-x86_64) GAIA_PLATFORM="darwin_amd64" ;;
  Darwin-arm64)  GAIA_PLATFORM="darwin_arm64" ;;
  Linux-x86_64)  GAIA_PLATFORM="linux_amd64"  ;;
  *) echo "Invalid platform"; exit 1 ;;
esac

if [[ -z $(which "wget" || true) ]]; then
  echo "ERROR: wget is not installed"
  exit 1
fi

if [[ $CLEANUP -eq "1" ]]; then
  echo "Deleting all local data"
  rm -rf ./tmp/ > /dev/null
fi

echo "Setting up working directory"
mkdir -p tmp
pushd tmp

echo "Your platform is $OS_PLATFORM/$OS_ARCH"

if [ ! -f "gaiad" ]; then
  echo "Downloading gaiad $GAIA_VERSION binary"
  wget --quiet -O ./gaiad "https://github.com/figment-networks/gaia-dm/releases/download/$GAIA_VERSION/gaiad_${GAIA_VERSION}_firehose_$GAIA_PLATFORM"
  chmod +x ./gaiad
fi

if [ ! -d "gaia_home" ]; then
  echo "Configuring home directory"
  ./gaiad --home=gaia_home init $(hostname) --chain-id localnet 2> /dev/null
fi

case $NETWORK in
  mainnet) # Using addrbook will ensure fast block sync time
    if [ ! -f "gaia_home/config/addrbook.json" ]; then
      echo "Downloading address book"
      wget --quiet -O gaia_home/config/addrbook.json $GAIA_ADDRESS_BOOK
    fi
    if [ ! -d "gaia_home" ]; then
      rm -f \
        gaia_home/config/genesis.json \
        gaia_home/config/addrbook.json
    fi
    if [ ! -f "gaia_home/config/genesis.json" ]; then
      echo "Downloading genesis file"
      wget --quiet -O gaia_home/config/genesis.json.gz $GAIA_GENESIS
      gunzip gaia_home/config/genesis.json.gz
    fi
  ;;
  testnet) # There's no address book for the testnet, use seeds instead
    if [ ! -d "gaia_home" ]; then
      rm -f \
        gaia_home/config/genesis.json \
        gaia_home/config/addrbook.json
    fi
    if [ ! -f "gaia_home/config/genesis.json" ]; then
      echo "Downloading genesis file"
      wget --quiet -O gaia_home/config/genesis.json.gz $GAIA_GENESIS
      gunzip gaia_home/config/genesis.json.gz
    fi
    echo "Configuring p2p seeds"
    sed -i -e 's/seeds = ""/seeds = "639d50339d7045436c756a042906b9a69970913f@seed-01.theta-testnet.polypore.xyz:26656,3e506472683ceb7ed75c1578d092c79785c27857@seed-02.theta-testnet.polypore.xyz:26656"/g' gaia_home/config/config.toml
  ;;
  localnet) # Setup localnet
    echo "Adding genesis accounts..."
    echo $MNEMONIC_1 | ./gaiad --home gaia_home keys add validator --recover --keyring-backend=test 
    echo $MNEMONIC_2 | ./gaiad --home gaia_home keys add user1 --recover --keyring-backend=test 
    echo $MNEMONIC_3 | ./gaiad --home gaia_home keys add user2 --recover --keyring-backend=test 
    ./gaiad --home gaia_home add-genesis-account $(./gaiad --home gaia_home keys show validator --keyring-backend test -a) $GENESIS_COINS
    ./gaiad --home gaia_home add-genesis-account $(./gaiad --home gaia_home keys show user1 --keyring-backend test -a) $GENESIS_COINS
    ./gaiad --home gaia_home add-genesis-account $(./gaiad --home gaia_home keys show user2 --keyring-backend test -a) $GENESIS_COINS

    echo "Creating and collecting gentx..."
    ./gaiad --home gaia_home gentx validator 1000000000stake --chain-id localnet --keyring-backend test
    ./gaiad --home gaia_home collect-gentxs
  ;;
esac

cat << END >> gaia_home/config/config.toml

#######################################################
###       Extractor Configuration Options     ###
#######################################################
[extractor]
enabled = true
output_file = "stdout"
END

if [ ! -f "firehose.yml" ]; then
  cat << END >> firehose.yml
start:
  args:
    - ingestor
    - merger
    - firehose
  flags:
    common-first-streamable-block: $GAIA_GENESIS_HEIGHT
    common-blockstream-addr: localhost:9000
    ingestor-mode: node
    ingestor-node-path: ./gaiad
    ingestor-node-args: start --x-crisis-skip-assert-invariants --home=./gaia_home
    ingestor-node-logs-filter: "module=(p2p|pex|consensus|x/bank)"
    firehose-real-time-tolerance: 99999h
    relayer-max-source-latency: 99999h
    verbose: 1
END
fi
