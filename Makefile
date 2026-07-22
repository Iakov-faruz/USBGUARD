.PHONY: install uninstall status clean

install:
	sudo bash install.sh

uninstall:
	sudo bash install.sh --uninstall

status:
	protector status

clean:
	systemctl stop usbguard-behavioral.service
	systemctl stop usbguard-ttl-reaper.timer
	systemctl stop usbguard-protector.service
