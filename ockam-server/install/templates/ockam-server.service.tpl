[Unit]
Description=Ockam server node (data-plane TCP listener on 14000)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ockam
Group=ockam
Environment=OCKAM_HOME=@OCKAM_HOME@
Environment=HOME=@OCKAM_HOME@
ExecStart=@OCKAM_BINARY@ node create @OCKAM_NODE_NAME@ --tcp-listener-address @OCKAM_NODE_TRANSPORT@ --foreground
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/ockam/node.log
StandardError=append:/var/log/ockam/node.err
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
