###boostrap chain
bash devel/osmosis1/bootstrap.sh

###start firehose and osmosis node
bash devel/osmosis1/start.sh

sleep 7m
###wait 100 blocks
cd graphnode-data
docker-compose up -d


graph-node --config ./config.toml --ipfs 127.0.0.1:5001 --node-id index_node_cosmos_1 &> ./logs/graphnode.log

