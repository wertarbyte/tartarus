RELEASE=

mandir=man

manpages = tartarus.1 \
           charon.ftp.1 \
           charon.local.1 \
           charon.pipe.1

.PHONY: all clean

all: $(addprefix $(mandir)/, $(manpages))

man:
	mkdir -p man

$(mandir)/tartarus.1: bin/tartarus man
	sed -rn 's!^# ?!!p' $< | pod2man --release="$(RELEASE)" --name tartarus --center=" " > $@

$(mandir)/%.1: bin/% man
	pod2man $< --release="$(RELEASE)" --name $* --center=" " > $@

clean:
	-rm $(addprefix $(mandir)/, $(manpages))
	-rm -fr man
