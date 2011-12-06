# extreact release version from tartarus script
RELEASE:=$(shell grep '^readonly VERSION="' bin/tartarus | cut -d\" -f 2)

PREFIX:=/usr/
DESTDIR:=/
BINDIR:=$(DESTDIR)/$(PREFIX)/sbin/
MANPAGEDIR:=$(DESTDIR)/$(PREFIX)/share/man/man1/

mandir=man

manpages = tartarus.1 \
           charon.1 \
           charon.ftp.1 \
           charon.local.1 \
           charon.pipe.1

.PHONY: all clean

all: $(addprefix $(mandir)/, $(manpages))

man:
	mkdir -p man

$(mandir)/tartarus.1: bin/tartarus man
	sed -rn 's!^# ?!!p' $< | pod2man --release="$(RELEASE)" --name tartarus --center=" " > $@

$(mandir)/charon.1: $(mandir)/charon.ftp.1
	ln -sf $(notdir $<) $@

$(mandir)/%.1: bin/% man
	pod2man $< --release="$(RELEASE)" --name $* --center=" " > $@

install: all
	install -d $(MANPAGEDIR)/ -m 755
	install -t $(MANPAGEDIR)/ $(addprefix $(mandir)/, $(manpages))

clean:
	-rm $(addprefix $(mandir)/, $(manpages))
	-rm -fr man
