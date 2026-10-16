# SPDX-License-Identifier: AGPL-3.0-or-later

# Essai d'une version de Crystal sur tous les projets du poste, sans changer
# la version utilisée au quotidien (README). Pour chaque projet (dossier qui
# contient un `shard.yml`), vérifie le typage complet (`crystal build
# --no-codegen`) de ses cibles et de ses specs avec la version de référence
# puis avec la nouvelle, et signale les régressions : ce qui passait avec la
# référence et ne passe plus avec la nouvelle. N'écrit rien dans les
# projets : ni `shards install`, ni binaire.
require "option_parser"
require "yaml"

module CrystalBeforeUpgrade
  VERSION = {{ read_file("#{__DIR__}/../shard.yml").lines.find(&.starts_with?("version:")).split(":").last.strip }}

  # Dossiers jamais explorés à la recherche de projets.
  IGNORES = %w[lib node_modules bin tmp .git .shards]

  # Résultat d'une vérification : succès, échec, ou impossible (dépendances
  # absentes, compilateur introuvable) ; `detail` = première erreur utile.
  record Verdict, statut : Symbol, detail : String = "", duree : Time::Span = Time::Span.zero do
    def ok? : Bool
      statut == :ok
    end
  end

  record Projet, chemin : String, fichiers : Array(String)

  class Erreur < Exception
  end

  # Projets sous `racine`, jusqu'à `profondeur` niveaux : on ne descend pas
  # dans un projet trouvé (ses `lib/` contiennent d'autres shard.yml).
  def self.projets(racine : String, profondeur : Int32 = 3) : Array(String)
    trouves = [] of String
    explorer(File.expand_path(racine), profondeur, trouves)
    trouves.sort
  end

  private def self.explorer(dossier : String, reste : Int32, trouves : Array(String)) : Nil
    if File.exists?(File.join(dossier, "shard.yml"))
      trouves << dossier
      return
    end
    return if reste <= 0
    Dir.each_child(dossier) do |nom|
      next if nom.starts_with?('.') || IGNORES.includes?(nom)
      chemin = File.join(dossier, nom)
      explorer(chemin, reste - 1, trouves) if File.directory?(chemin) && !File.symlink?(chemin)
    end
  rescue File::Error
    # Dossier illisible : ignoré.
  end

  # Fichiers à vérifier : le `main` de chaque cible du shard.yml, puis les
  # specs (`spec/**/*_spec.cr`). Chemins relatifs au projet, sans doublon.
  def self.fichiers(projet : String) : Array(String)
    liste = [] of String
    begin
      yaml = YAML.parse(File.read(File.join(projet, "shard.yml")))
      yaml["targets"]?.try(&.as_h?).try &.each_value do |cible|
        if principal = cible["main"]?.try(&.as_s?)
          liste << principal if File.exists?(File.join(projet, principal))
        end
      end
    rescue YAML::ParseException
    end
    specs = Dir.glob(File.join(projet, "spec", "**", "*_spec.cr")).sort.map { |chemin| chemin[(projet.size + 1)..] }
    (liste + specs).uniq
  end

  # Compilateur d'une version installée par asdf (son script `bin/crystal`
  # règle lui-même CRYSTAL_PATH), ou chemin donné tel quel.
  def self.compilateur(version : String, asdf : String) : String
    chemin = version.includes?('/') ? version : File.join(asdf, "installs", "crystal", version, "bin", "crystal")
    raise Erreur.new("compilateur introuvable : #{chemin} (asdf install crystal #{version} ?)") unless File::Info.executable?(chemin)
    chemin
  end

  # Typage complet, sans génération de code. Les cibles et les specs sont
  # vérifiées séparément : deux `main` dans une même compilation
  # s'exécuteraient l'un à la suite de l'autre et pourraient se gêner.
  def self.verifier(crystal : String, projet : Projet) : Verdict
    debut = Time.monotonic
    return Verdict.new(:impossible, "rien à vérifier (ni cible ni spec)") if projet.fichiers.empty?
    unless Dir.exists?(File.join(projet.chemin, "lib")) || !dependances?(projet.chemin)
      return Verdict.new(:impossible, "dépendances absentes : shards install")
    end
    cibles, specs = projet.fichiers.partition { |fichier| !fichier.starts_with?("spec/") }
    groupes = cibles.map { |cible| [cible] }
    groupes << specs unless specs.empty?
    groupes.each do |groupe|
      sortie = IO::Memory.new
      statut = Process.run(crystal, ["build", "--no-codegen", "--no-color"] + groupe,
        chdir: projet.chemin, output: sortie, error: sortie, input: Process::Redirect::Close)
      unless statut.success?
        return Verdict.new(:echec, premiere_erreur(sortie.to_s, groupe.first), Time.monotonic - debut)
      end
    end
    Verdict.new(:ok, "", Time.monotonic - debut)
  end

  private def self.dependances?(projet : String) : Bool
    yaml = YAML.parse(File.read(File.join(projet, "shard.yml")))
    %w[dependencies development_dependencies].any? { |cle| yaml[cle]?.try(&.as_h?).try(&.empty?) == false }
  rescue YAML::ParseException
    false
  end

  # Ligne la plus parlante d'une sortie de compilation : la première
  # « Error: », sinon la dernière ligne non vide.
  def self.premiere_erreur(sortie : String, fichier : String) : String
    lignes = sortie.lines.map(&.strip).reject(&.empty?)
    erreur = lignes.find(&.starts_with?("Error:")) || lignes.last? || "échec sans message"
    "#{fichier} : #{erreur.lchop("Error: ")}"
  end

  # Régression : la référence passe, la nouvelle version non.
  def self.regression?(reference : Verdict?, nouvelle : Verdict) : Bool
    !nouvelle.ok? && nouvelle.statut != :impossible && (reference.nil? || reference.ok?)
  end

  def self.etiquette(verdict : Verdict?) : String
    return "—" unless verdict
    case verdict.statut
    when :ok    then "ok (#{verdict.duree.total_seconds.round.to_i} s)"
    when :echec then "ÉCHEC"
    else             "impossible"
    end
  end

  # Tableau final : régressions d'abord, puis échecs déjà présents avec la
  # référence, puis le reste ; noms relatifs à la racine commune.
  def self.rapport(resultats : Array({Projet, Verdict?, Verdict}), reference : String?, nouvelle : String, io : IO) : Nil
    tries = resultats.sort_by do |(projet, ref, neuf)|
      rang = regression?(ref, neuf) ? 0 : (neuf.ok? ? 2 : 1)
      {rang, projet.chemin}
    end
    largeur = tries.max_of? { |(projet, _, _)| nom(projet.chemin).size } || 10
    io.puts
    entete = reference ? "#{"projet".ljust(largeur)}  #{reference.ljust(14)}  #{nouvelle}" : "#{"projet".ljust(largeur)}  #{nouvelle}"
    io.puts entete
    io.puts "-" * (entete.size + 12)
    tries.each do |(projet, ref, neuf)|
      marque = regression?(ref, neuf) ? "✗" : (neuf.ok? ? " " : "·")
      colonnes = reference ? "#{etiquette(ref).ljust(14)}  #{etiquette(neuf)}" : etiquette(neuf)
      io.puts "#{nom(projet.chemin).ljust(largeur)}  #{colonnes} #{marque}"
      io.puts "    #{neuf.detail}" unless neuf.ok? || neuf.detail.empty?
    end
    regressions = tries.count { |(_, ref, neuf)| regression?(ref, neuf) }
    io.puts
    io.puts "#{tries.size} projet(s) ; #{regressions} régression(s) avec #{nouvelle}" +
            (reference ? " par rapport à #{reference}" : "") + " (✗ régression, · échec déjà présent ou vérification impossible)"
  end

  private def self.nom(chemin : String) : String
    chemin.sub(Path.home.to_s, "~")
  end

  def self.main(arguments : Array(String), io : IO = STDOUT) : Int32
    racines = [] of String
    reference : String? = ENV["CRYSTAL_BEFORE_UPGRADE_REFERENCE"]?
    asdf = ENV["ASDF_DATA_DIR"]? || File.join(Path.home.to_s, ".asdf")
    filtre : String? = nil
    travaux = 2
    nouvelle : String? = nil
    aide = false
    montrer_version = false

    parseur = OptionParser.new do |p|
      p.banner = "Usage : crystal-before-upgrade VERSION [options]\n\n" \
                 "Vérifie le typage de tous les projets avec Crystal VERSION (installée par asdf),\n" \
                 "en le comparant à la version de référence. N'écrit rien dans les projets.\n"
      p.on("-r DIR", "--racine=DIR", "Dossier où chercher les projets (répétable ; défaut : ~/prod-crystal, ~/prod-partiduo)") { |v| racines << v }
      p.on("--reference=VERSION", "Version de référence (défaut : $CRYSTAL_BEFORE_UPGRADE_REFERENCE, sinon aucune comparaison)") { |v| reference = v }
      p.on("--sans-reference", "Ne vérifier qu'avec VERSION") { reference = nil }
      p.on("-f MOTIF", "--filtre=MOTIF", "Seulement les projets dont le chemin contient MOTIF") { |v| filtre = v }
      p.on("-j N", "--travaux=N", "Projets vérifiés en même temps (défaut : 2 ; la mémoire limite)") { |v| travaux = v.to_i.clamp(1, 16) }
      p.on("--asdf=DIR", "Dossier d'asdf (défaut : $ASDF_DATA_DIR ou ~/.asdf)") { |v| asdf = v }
      p.on("-V", "--version", "Version de crystal-before-upgrade") { montrer_version = true }
      p.on("-h", "--help", "Aide") { aide = true }
      p.unknown_args { |reste, _| nouvelle = reste.first? }
      p.invalid_option { |option| raise Erreur.new("option inconnue : #{option}") }
    end
    parseur.parse(arguments)
    if montrer_version
      io.puts "crystal-before-upgrade #{VERSION}"
      return 0
    end
    if aide || nouvelle.nil?
      io.puts parseur
      return aide ? 0 : 2
    end
    cible = nouvelle.not_nil!
    racines = [File.join(Path.home.to_s, "prod-crystal"), File.join(Path.home.to_s, "prod-partiduo")] if racines.empty?

    crystal_neuf = compilateur(cible, asdf)
    crystal_ref = reference.try { |version| compilateur(version, asdf) }

    chemins = racines.flat_map { |racine| projets(racine) }.uniq
    chemins.select! { |chemin| chemin.includes?(filtre.not_nil!) } if filtre
    liste = chemins.map { |chemin| Projet.new(chemin, fichiers(chemin)) }
    io.puts "crystal-before-upgrade : #{liste.size} projet(s), #{cible}#{reference ? " comparée à #{reference}" : ""}, #{travaux} à la fois"

    resultats = Array({Projet, Verdict?, Verdict}).new
    file = Channel(Projet).new(liste.size)
    retours = Channel({Projet, Verdict?, Verdict}).new
    liste.each { |projet| file.send(projet) }
    file.close
    travaux.times do
      spawn do
        while projet = file.receive?
          ref = crystal_ref.try { |compilo| verifier(compilo, projet) }
          retours.send({projet, ref, verifier(crystal_neuf, projet)})
        end
      end
    end
    liste.size.times do |rang|
      resultat = retours.receive
      resultats << resultat
      io.puts "  [#{rang + 1}/#{liste.size}] #{nom(resultat[0].chemin)} : #{etiquette(resultat[2])}"
    end

    rapport(resultats, reference, cible, io)
    resultats.any? { |(_, ref, neuf)| regression?(ref, neuf) } ? 1 : 0
  rescue ex : Erreur | OptionParser::Exception
    STDERR.puts "crystal-before-upgrade : #{ex.message}"
    2
  end
end
