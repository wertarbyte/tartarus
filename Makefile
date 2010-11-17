# extreact release version from tartarus script
RELEASE:=$(shell grep '^readonly VERSION="' bin/tartarus | cut -d\" -f 2)

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
	ln -s $(notdir $<) $@

$(mandir)/%.1: bin/% man
	pod2man $< --release="$(RELEASE)" --name $* --center=" " > $@

clean:
	-rm $(addprefix $(mandir)/, $(manpages))
	-rm -fr man
