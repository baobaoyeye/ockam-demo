[Unit]
Description=Ockam controller (control-plane HTTP API on 127.0.0.1:8080)
After=ockam-server.service
Requires=ockam-server.service

[Service]
Type=simple
User=ockam
Group=ockam
Environment=OCKAM_HOME=@OCKAM_HOME@
Environment=HOME=@OCKAM_HOME@
Environment=OCKAM_BINARY=@OCKAM_BINARY@
Environment=OCKAM_CONTROLLER_STATE=@OCKAM_CONTROLLER_STATE@
Environment=OCKAM_NODE_NAME=@OCKAM_NODE_NAME@
Environment=OCKAM_NODE_TRANSPORT=@OCKAM_NODE_TRANSPORT@
Environment=OCKAM_CONTROLLER_TRUST_ALL=1
ExecStart=@PYTHON@ -m ockam_controller --bind 127.0.0.1:8080 --state @OCKAM_CONTROLLER_STATE@
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/ockam/controller.log
StandardError=append:/var/log/ockam/controller.err

[Install]
WantedBy=multi-user.target
