# SPDX-License-Identifier: AGPL-3.0-or-later

require "spec"
require "file_utils"
require "../src/crystal-before-upgrade"

private def arbre(&)
  racine = File.join(Dir.tempdir, "crystal-before-upgrade-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(racine)
  yield racine
ensure
  FileUtils.rm_rf(racine) if racine
end

private def projet(dossier : String, shard : String, fichiers = {} of String => String) : Nil
  Dir.mkdir_p(dossier)
  File.write(File.join(dossier, "shard.yml"), shard)
  fichiers.each do |chemin, contenu|
    Dir.mkdir_p(File.dirname(File.join(dossier, chemin)))
    File.write(File.join(dossier, chemin), contenu)
  end
end

describe CrystalBeforeUpgrade do
  it "trouve les projets sans descendre dans un projet ni dans lib/" do
    arbre do |racine|
      projet(File.join(racine, "a"), "name: a\n")
      projet(File.join(racine, "a", "lib", "dep"), "name: dep\n")
      projet(File.join(racine, "ombrelle", "b"), "name: b\n")
      projet(File.join(racine, "lib", "c"), "name: c\n")
      CrystalBeforeUpgrade.projets(racine).map { |chemin| File.basename(chemin) }.should eq(["a", "b"])
    end
  end

  it "vérifie les cibles du shard.yml puis les specs" do
    arbre do |racine|
      dossier = File.join(racine, "p")
      projet(dossier, "name: p\ntargets:\n  p:\n    main: src/p.cr\n  absent:\n    main: src/absent.cr\n",
        {"src/p.cr" => "", "spec/z_spec.cr" => "", "spec/sous/a_spec.cr" => "", "spec/spec_helper.cr" => ""})
      CrystalBeforeUpgrade.fichiers(dossier).should eq(["src/p.cr", "spec/sous/a_spec.cr", "spec/z_spec.cr"])
    end
  end

  it "tire la première erreur utile d'une sortie de compilation" do
    sortie = "Showing last frame.\n\nIn lib/jose/src/jose/openssl_ext.cr:82:3\n\nError: already initialized constant LibCrypto::X\n"
    CrystalBeforeUpgrade.premiere_erreur(sortie, "spec/a_spec.cr").should eq("spec/a_spec.cr : already initialized constant LibCrypto::X")
    CrystalBeforeUpgrade.premiere_erreur("", "src/p.cr").should eq("src/p.cr : échec sans message")
  end

  it "ne compte en régression que ce qui passait avec la référence" do
    ok = CrystalBeforeUpgrade::Verdict.new(:ok)
    echec = CrystalBeforeUpgrade::Verdict.new(:echec, "x")
    impossible = CrystalBeforeUpgrade::Verdict.new(:impossible, "shards install")
    CrystalBeforeUpgrade.regression?(ok, echec).should be_true
    CrystalBeforeUpgrade.regression?(nil, echec).should be_true
    CrystalBeforeUpgrade.regression?(echec, echec).should be_false
    CrystalBeforeUpgrade.regression?(ok, impossible).should be_false
    CrystalBeforeUpgrade.regression?(ok, ok).should be_false
  end

  it "vérifie un vrai projet et signale une régression simulée" do
    arbre do |racine|
      dossier = File.join(racine, "p")
      projet(dossier, "name: p\ntargets:\n  p:\n    main: src/p.cr\n", {"src/p.cr" => "puts 1 + 1\n"})
      compilo = CrystalBeforeUpgrade.compilateur(Process.find_executable("crystal").not_nil!, "/nonexistent")
      cas = CrystalBeforeUpgrade::Projet.new(dossier, CrystalBeforeUpgrade.fichiers(dossier))
      CrystalBeforeUpgrade.verifier(compilo, cas).ok?.should be_true
      File.write(File.join(dossier, "src/p.cr"), "puts 1 + \"a\"\n")
      verdict = CrystalBeforeUpgrade.verifier(compilo, cas)
      verdict.statut.should eq(:echec)
      verdict.detail.should start_with("src/p.cr : ")
    end
  end

  it "refuse une version qu'asdf n'a pas installée" do
    expect_raises(CrystalBeforeUpgrade::Erreur, /asdf install crystal 9.9.9/) { CrystalBeforeUpgrade.compilateur("9.9.9", "/nonexistent") }
  end
end
