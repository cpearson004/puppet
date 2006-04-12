class Puppet::SSLCertificates::CA
    Certificate = Puppet::SSLCertificates::Certificate
    attr_accessor :keyfile, :file, :config, :dir, :cert

    Puppet.setdefaults(:ca,
        :cadir => {  :default => "$ssldir/ca",
            :owner => "$user",
            :group => "$group",
            :mode => 0770,
            :desc => "The root directory for the certificate authority."
        },
        :cacert => { :default => "$cadir/ca_crt.pem",
            :owner => "$user",
            :group => "$group",
            :mode => 0660,
            :desc => "The CA certificate."
        },
        :cakey => { :default => "$cadir/ca_key.pem",
            :owner => "$user",
            :group => "$group",
            :mode => 0660,
            :desc => "The CA private key."
        },
        :capub => { :default => "$cadir/ca_pub.pem",
            :owner => "$user",
            :group => "$group",
            :desc => "The CA public key."
        },
        :caprivatedir => { :default => "$cadir/private",
            :owner => "$user",
            :group => "$group",
            :mode => 0770,
            :desc => "Where the CA stores private certificate information."
        },
        :csrdir => { :default => "$cadir/requests",
            :owner => "$user",
            :group => "$group",
            :desc => "Where the CA stores certificate requests"
        },
        :signeddir => { :default => "$cadir/signed",
            :owner => "$user",
            :group => "$group",
            :mode => 0770,
            :desc => "Where the CA stores signed certificates."
        },
        :capass => { :default => "$caprivatedir/ca.pass",
            :owner => "$user",
            :group => "$group",
            :mode => 0660,
            :desc => "Where the CA stores the password for the private key"
        },
        :serial => { :default => "$cadir/serial",
            :owner => "$user",
            :group => "$group",
            :desc => "Where the serial number for certificates is stored."
        },
        :autosign => { :default => "$confdir/autosign.conf",
            :mode => 0640,
            :desc => "Whether to enable autosign.  Valid values are true (which
                autosigns any key request, and is a very bad idea), false (which
                never autosigns any key request), and the path to a file, which
                uses that configuration file to determine which keys to sign."},
        :ca_days => [1825, "How long a certificate should be valid."],
        :ca_md => ["md5", "The type of hash used in certificates."],
        :req_bits => [2048, "The bit length of the certificates."],
        :keylength => [1024, "The bit length of keys."]
    )

    def certfile
        @config[:cacert]
    end

    def host2csrfile(hostname)
        File.join(Puppet[:csrdir], [hostname, "pem"].join("."))
    end

    # this stores signed certs in a directory unrelated to 
    # normal client certs
    def host2certfile(hostname)
        File.join(Puppet[:signeddir], [hostname, "pem"].join("."))
    end

    # Turn our hostname into a Name object
    def thing2name(thing)
        thing.subject.to_a.find { |ary|
            ary[0] == "CN"
        }[1]
    end

    def initialize(hash = {})
        Puppet.config.use(:puppet, :certificates, :ca)
        self.setconfig(hash)

        if Puppet[:capass]
            if FileTest.exists?(Puppet[:capass])
                #puts "Reading %s" % Puppet[:capass]
                #system "ls -al %s" % Puppet[:capass]
                #File.read Puppet[:capass]
                @config[:password] = self.getpass
            else
                # Don't create a password if the cert already exists
                unless FileTest.exists?(@config[:cacert])
                    @config[:password] = self.genpass
                end
            end
        end

        self.getcert
        unless FileTest.exists?(@config[:serial])
            Puppet.config.write(:serial) do |f|
                f << "%04X" % 1
            end
        end
    end

    # Generate a new password for the CA.
    def genpass
        pass = ""
        20.times { pass += (rand(74) + 48).chr }

        begin
            Puppet.config.write(:capass) { |f| f.print pass }
        rescue Errno::EACCES => detail
            raise Puppet::Error, detail.to_s
        end
        return pass
    end

    # Get the CA password.
    def getpass
        if @config[:capass] and File.readable?(@config[:capass])
            return File.read(@config[:capass])
        else
            raise Puppet::Error, "Could not read CA passfile %s" % @config[:capass]
        end
    end

    # Get the CA cert.
    def getcert
        if FileTest.exists?(@config[:cacert])
            @cert = OpenSSL::X509::Certificate.new(
                File.read(@config[:cacert])
            )
        else
            self.mkrootcert
        end
    end

    # Retrieve a client's CSR.
    def getclientcsr(host)
        csrfile = host2csrfile(host)
        unless File.exists?(csrfile)
            return nil
        end

        return OpenSSL::X509::Request.new(File.read(csrfile))
    end

    # Retrieve a client's certificate.
    def getclientcert(host)
        certfile = host2certfile(host)
        unless File.exists?(certfile)
            return [nil, nil]
        end

        return [OpenSSL::X509::Certificate.new(File.read(certfile)), @cert]
    end

    # List certificates waiting to be signed.
    def list
        return Dir.entries(Puppet[:csrdir]).reject { |file|
            file =~ /^\.+$/
        }.collect { |file|
            file.sub(/\.pem$/, '')
        }
    end

    # Create the root certificate.
    def mkrootcert
        cert = Certificate.new(
            :name => "CAcert",
            :cert => @config[:cacert],
            :encrypt => @config[:capass],
            :key => @config[:cakey],
            :selfsign => true,
            :length => 1825,
            :type => :ca
        )

        # This creates the cakey file
        Puppet::Util.asuser(Puppet[:user], Puppet[:group]) do
            @cert = cert.mkselfsigned
        end
        Puppet.config.write(:cacert) do |f|
            f.puts @cert.to_pem
        end
        @key = cert.key
        return cert
    end

    def removeclientcsr(host)
        csrfile = host2csrfile(host)
        unless File.exists?(csrfile)
            raise Puppet::Error, "No certificate request for %s" % host
        end

        File.unlink(csrfile)
    end

    # Take the Puppet config and store it locally.
    def setconfig(hash)
        @config = {}
        Puppet.config.params("ca").each { |param|
            param = param.intern if param.is_a? String
            if hash.include?(param)
                @config[param] = hash[param]
                Puppet[param] = hash[param]
                hash.delete(param)
            else
                @config[param] = Puppet[param]
            end
        }

        if hash.include?(:password)
            @config[:password] = hash[:password]
            hash.delete(:password)
        end

        if hash.length > 0
            raise ArgumentError, "Unknown parameters %s" % hash.keys.join(",")
        end

        [:cadir, :csrdir, :signeddir].each { |dir|
            unless @config[dir]
                raise Puppet::DevError, "%s is undefined" % dir
            end
        }
    end

    # Sign a given certificate request.
    def sign(csr)
        unless csr.is_a?(OpenSSL::X509::Request)
            raise Puppet::Error,
                "CA#sign only accepts OpenSSL::X509::Request objects, not %s" %
                csr.class
        end

        unless csr.verify(csr.public_key)
            raise Puppet::Error, "CSR sign verification failed"
        end

        # i should probably check key length...

        # read the ca cert in
        cacert = OpenSSL::X509::Certificate.new(
            File.read(@config[:cacert])
        )

        cakey = nil
        if @config[:password]
            cakey = OpenSSL::PKey::RSA.new(
                File.read(@config[:cakey]), @config[:password]
            )
        else
            cakey = OpenSSL::PKey::RSA.new(
                File.read(@config[:cakey])
            )
        end

        unless cacert.check_private_key(cakey)
            raise Puppet::Error, "CA Certificate is invalid"
        end

        serial = File.read(@config[:serial]).chomp.hex
        newcert = Puppet::SSLCertificates.mkcert(
            :type => :server,
            :name => csr.subject,
            :days => @config[:ca_days],
            :issuer => cacert,
            :serial => serial,
            :publickey => csr.public_key
        )

        # increment the serial
        Puppet.config.write(:serial) do |f|
            f << "%04X" % (serial + 1)
        end

        newcert.sign(cakey, OpenSSL::Digest::SHA1.new)

        self.storeclientcert(newcert)

        return [newcert, cacert]
    end

    # Store the client's CSR for later signing.  This is called from
    # server/ca.rb, and the CSRs are deleted once the certificate is actually
    # signed.
    def storeclientcsr(csr)
        host = thing2name(csr)

        csrfile = host2csrfile(host)
        if File.exists?(csrfile)
            raise Puppet::Error, "Certificate request for %s already exists" % host
        end

        Puppet.config.writesub(:csrdir, csrfile) do |f|
            f.print csr.to_pem
        end
    end

    # Store the certificate that we generate.
    def storeclientcert(cert)
        host = thing2name(cert)

        certfile = host2certfile(host)
        if File.exists?(certfile)
            Puppet.notice "Overwriting signed certificate %s for %s" %
                [certfile, host]
        end

        Puppet.config.writesub(:signeddir, certfile) do |f|
            f.print cert.to_pem
        end
    end
end

# $Id$
