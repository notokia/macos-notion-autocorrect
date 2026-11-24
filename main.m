#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <stdatomic.h>
#import <unistd.h>

static const int64_t kSyntheticEventMagic = 0x4E4F544E; // 'NOTN'
static const CGKeyCode kKeyCodeBackspace = 51;
static const CGKeyCode kKeyCodeSpace     = 49;
static const CGKeyCode kKeyCodeReturn    = 36;
static const CGKeyCode kKeyCodeEnter     = 76;
static const CGKeyCode kKeyCodeTab       = 48;
static const CGKeyCode kKeyCodeEscape    = 53;

@interface NotionAutocorrectController : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSWindow *mainWindow;
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (nonatomic, assign) CFRunLoopSourceRef runLoopSource;

// Settings
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL expandAbbreviations;
@property (nonatomic, copy) NSString *currentLanguage;

// State
@property (nonatomic, strong) NSMutableString *wordBuffer;
@property (nonatomic, strong) NSMutableString *sentenceBuffer;
@property (nonatomic, copy) NSString *detectedPrimaryLanguage;
@property (nonatomic, copy) NSString *lastActiveLanguage;
@property (nonatomic, assign) BOOL skipCurrentWord;
@property (nonatomic, assign) BOOL wordHasTrailingDot;
@property (nonatomic, assign) BOOL lastKnownTrusted;
@property (nonatomic, assign) UInt32 deadKeyState;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *builtinByLang;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *abbrevByLang;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *systemReplacementsMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *customMap;
@property (nonatomic, strong) NSMutableArray<NSString *> *sortedCustomKeys;
@property (nonatomic, strong) NSMutableSet<NSString *> *ignoredWordsSet;
@property (nonatomic, strong) NSMutableArray<NSString *> *sortedIgnoredWords;
@property (nonatomic, strong) NSMutableSet<NSString *> *ignoredOnceWords;
@property (nonatomic, assign) NSInteger spellDocTag;
@property (nonatomic, strong) dispatch_queue_t sendQueue;

// Undo state
@property (nonatomic, assign) BOOL canUndoLastCorrection;
@property (nonatomic, copy) NSString *lastOriginalWord;
@property (nonatomic, copy) NSString *lastCorrectedWord;
@property (nonatomic, copy) NSString *lastCorrectionDisplay;

// Menu items
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *lastCorrectionMenuItem;
@property (nonatomic, strong) NSMenuItem *enableMenuItem;
@property (nonatomic, strong) NSMenuItem *abbrevMenuItem;
@property (nonatomic, strong) NSMenuItem *accessibilityMenuItem;

// Window UI controls
@property (nonatomic, strong) NSTextField *statusBannerLabel;
@property (nonatomic, strong) NSButton *openAccessBtn;
@property (nonatomic, strong) NSButton *enableCheckbox;
@property (nonatomic, strong) NSButton *abbrevCheckbox;
@property (nonatomic, strong) NSButton *launchAtLoginCheckbox;
@property (nonatomic, strong) NSPopUpButton *languagePopup;
@property (nonatomic, strong) NSTextField *lastCorrLabel;
@property (nonatomic, strong) NSTableView *shortcutsTable;
@property (nonatomic, strong) NSTextField *shortcutKeyInput;
@property (nonatomic, strong) NSTextField *shortcutValInput;
@property (nonatomic, strong) NSTextField *testInputField;
@property (nonatomic, strong) NSButton *ignoredWordsBtn;
@property (nonatomic, strong) NSWindow *ignoredWordsWindow;
@property (nonatomic, strong) NSTableView *ignoredTable;
@property (nonatomic, strong) NSTextField *ignoredWordInput;

@property (nonatomic, strong) NSArray<NSDictionary *> *supportedLanguages;
@property (nonatomic, strong) NSTimer *permissionTimer;
@property (nonatomic, copy) NSString *uiLang;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *uiStrings;
@end

static NotionAutocorrectController *gController = nil;
static _Atomic int32_t gActiveReplacementsCount = 0;

static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);

@implementation NotionAutocorrectController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    gController = self;
    self.isEnabled = YES;
    self.expandAbbreviations = YES;
    self.currentLanguage = @"auto";
    self.wordBuffer = [NSMutableString string];
    self.sentenceBuffer = [NSMutableString string];
    self.ignoredOnceWords = [NSMutableSet set];
    self.ignoredWordsSet = [NSMutableSet set];
    self.sortedIgnoredWords = [NSMutableArray array];
    self.sortedCustomKeys = [NSMutableArray array];
    self.systemReplacementsMap = [NSMutableDictionary dictionary];
    self.spellDocTag = [NSSpellChecker uniqueSpellDocumentTag];
    [NSSpellChecker sharedSpellChecker].automaticallyIdentifiesLanguages = YES;
    self.sendQueue = dispatch_queue_create("com.bernardo.NotionAutocorrect.sendQueue", DISPATCH_QUEUE_SERIAL);

    [self setupUILocalization];
    self.lastCorrectionDisplay = [self tr:@"none_yet"];

    [self setupSupportedLanguages];
    self.detectedPrimaryLanguage = [self detectPrimaryLanguageFromSystemAndNotion];
    self.lastActiveLanguage = self.detectedPrimaryLanguage;
    [self setupDictionaries];
    [self loadSystemTextReplacements];
    [self loadSettingsAndCustomDictionary];
    [self setupMainMenu];
    [self setupStatusBar];
    [self buildMainWindow];
    [self registerWorkspaceNotifications];
    [self startEventTapIfTrusted:YES];

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                        selector:@selector(runLiveSelfTestNotification:)
                                                            name:@"com.bernardo.NotionAutocorrect.runSelfTest"
                                                          object:nil];

    BOOL launchedInBackground = [[[NSProcessInfo processInfo] arguments] containsObject:@"--background"];
    if (!launchedInBackground || !AXIsProcessTrusted()) {
        [self showControlWindow:nil];
    }

    self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                            target:self
                                                          selector:@selector(checkPermissionsPeriodic)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO; // Continua rodando em segundo plano quando fecha a janela
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.mainWindow) {
        // Esconde do Cmd+Tab / Dock quando a janela fecha para evitar Cmd+Q acidental!
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.mainWindow.isVisible && (!self.ignoredWordsWindow || !self.ignoredWordsWindow.isVisible)) {
                [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            }
        });
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showControlWindow:nil];
    return YES;
}

- (void)setupUILocalization {
    NSString *sysLang = [[[NSLocale preferredLanguages] firstObject] lowercaseString] ?: @"en";
    if ([sysLang hasPrefix:@"pt"]) self.uiLang = @"pt";
    else if ([sysLang hasPrefix:@"es"]) self.uiLang = @"es";
    else if ([sysLang hasPrefix:@"fr"]) self.uiLang = @"fr";
    else self.uiLang = @"en";

    self.uiStrings = @{
        @"en": @{
            @"win_title": @"NotionAutocorrect — Control Panel",
            @"subtitle": @"Real-time native autocorrection for Notion Desktop (100% Offline)",
            @"auto_lang": @"🌐 Auto (Smart Detection)",
            @"none_yet": @"None yet",
            @"status_init": @"Status: Initializing...",
            @"status_need_ax": @"⚠️ Accessibility permission required to work in Notion",
            @"status_paused": @"⏸ Autocorrection paused",
            @"status_ready": @"✅ All set! Running for Notion (%@ · %lu Mac shortcuts)",
            @"menu_need_ax": @"Status: Waiting for Accessibility permission",
            @"menu_paused": @"Status: Paused",
            @"menu_ready": @"Status: Running (%@)",
            @"btn_ax": @"Open Accessibility...",
            @"menu_ax": @"⚠️ Grant Accessibility Permission...",
            @"chk_enable": @"Enable automatic autocorrection while typing",
            @"chk_abbrev": @"Expand abbreviations & custom shortcuts",
            @"chk_login": @"Start automatically at login",
            @"lbl_lang": @"Spellcheck Language:",
            @"lbl_last": @"Last correction: %@  (press Backspace after space to undo)",
            @"menu_last": @"Last: %@",
            @"sec_shortcuts": @"Custom Shortcuts & Abbreviations",
            @"col_key": @"Shortcut (what you type)",
            @"col_val": @"Replace with",
            @"ph_key": @"e.g. omw",
            @"ph_val": @"e.g. On my way!",
            @"btn_save": @"Save",
            @"btn_remove": @"Remove",
            @"lbl_test": @"Test right here (type e.g. 'teh recieve btw '):",
            @"ph_test": @"Type here with spaces to test live autocorrection...",
            @"menu_open_panel": @"⚙️ Open NotionAutocorrect Panel...",
            @"menu_enable": @"Enable Autocorrection",
            @"menu_abbrev": @"Expand Abbreviations",
            @"menu_quit": @"Quit NotionAutocorrect",
            @"menu_close": @"Close Window",
            @"menu_edit": @"Edit",
            @"menu_undo": @"Undo",
            @"menu_cut": @"Cut",
            @"menu_copy": @"Copy",
            @"menu_paste": @"Paste",
            @"menu_select_all": @"Select All",
            @"undone": @"Undone & Ignored (%@)",
            @"btn_ignored": @"🚫 Ignored Words (%lu)",
            @"ign_win_title": @"Automatically Ignored Words",
            @"ign_subtitle": @"Words undone with Backspace are added here automatically and won't be corrected again.",
            @"ign_col": @"Ignored Word",
            @"ign_ph": @"Add word to ignore...",
            @"ign_add": @"Add",
            @"ign_remove": @"Restore Selected",
            @"ign_clear": @"Clear All"
        },
        @"pt": @{
            @"win_title": @"NotionAutocorrect — Painel de Controle",
            @"subtitle": @"Autocorreção nativa em tempo real para o Notion Desktop (100% Offline)",
            @"auto_lang": @"🌐 Automático (Detecção Inteligente)",
            @"none_yet": @"Nenhuma ainda",
            @"status_init": @"Status: Inicializando...",
            @"status_need_ax": @"⚠️ Ative a permissão em Acessibilidade para funcionar",
            @"status_paused": @"⏸ Autocorreção pausada",
            @"status_ready": @"✅ Tudo certo! Já está rodando no Notion (%@ · %lu atalhos)",
            @"menu_need_ax": @"Status: Aguardando permissão de Acessibilidade",
            @"menu_paused": @"Status: Pausado",
            @"menu_ready": @"Status: Rodando (%@)",
            @"btn_ax": @"Abrir Acessibilidade...",
            @"menu_ax": @"⚠️ Liberar Permissão de Acessibilidade...",
            @"chk_enable": @"Ativar autocorreção automática ao digitar",
            @"chk_abbrev": @"Expandir abreviações e atalhos personalizados",
            @"chk_login": @"Iniciar automaticamente ao ligar o Mac",
            @"lbl_lang": @"Idioma do Corretor:",
            @"lbl_last": @"Última correção: %@  (Backspace após espaço desfaz)",
            @"menu_last": @"Última: %@",
            @"sec_shortcuts": @"Atalhos e Abreviações Personalizadas",
            @"col_key": @"Atalho (o que você digita)",
            @"col_val": @"Substituir por",
            @"ph_key": @"Ex: adm",
            @"ph_val": @"Ex: Administração",
            @"btn_save": @"Salvar",
            @"btn_remove": @"Remover",
            @"lbl_test": @"Teste aqui mesmo (digite ex: 'vc nao sabe como essa informacao eh util '):",
            @"ph_test": @"Digite aqui com espaços para testar a autocorreção ao vivo...",
            @"menu_open_panel": @"⚙️ Abrir Painel do NotionAutocorrect...",
            @"menu_enable": @"Ativar Autocorreção",
            @"menu_abbrev": @"Expandir Abreviações",
            @"menu_quit": @"Sair do NotionAutocorrect",
            @"menu_close": @"Fechar Janela",
            @"menu_edit": @"Editar",
            @"menu_undo": @"Desfazer",
            @"menu_cut": @"Cortar",
            @"menu_copy": @"Copiar",
            @"menu_paste": @"Colar",
            @"menu_select_all": @"Selecionar Tudo",
            @"undone": @"Desfeito e Ignorado (%@)",
            @"btn_ignored": @"🚫 Palavras Ignoradas (%lu)",
            @"ign_win_title": @"Palavras Ignoradas Automaticamente",
            @"ign_subtitle": @"Palavras desfeitas com Backspace entram aqui automaticamente e não são mais corrigidas.",
            @"ign_col": @"Palavra Ignorada",
            @"ign_ph": @"Adicionar palavra para ignorar...",
            @"ign_add": @"Adicionar",
            @"ign_remove": @"Restaurar Selecionada",
            @"ign_clear": @"Limpar Tudo"
        },
        @"es": @{
            @"win_title": @"NotionAutocorrect — Panel de Control",
            @"subtitle": @"Autocorrección nativa en tiempo real para Notion Desktop (100% Offline)",
            @"auto_lang": @"🌐 Automático (Detección Inteligente)",
            @"none_yet": @"Ninguna aún",
            @"status_init": @"Estado: Inicializando...",
            @"status_need_ax": @"⚠️ Se requiere permiso de Accesibilidad para funcionar",
            @"status_paused": @"⏸ Autocorrección en pausa",
            @"status_ready": @"✅ ¡Todo listo! Funcionando en Notion (%@ · %lu atajos)",
            @"menu_need_ax": @"Estado: Esperando permiso de Accesibilidad",
            @"menu_paused": @"Estado: En pausa",
            @"menu_ready": @"Estado: Activo (%@)",
            @"btn_ax": @"Abrir Accesibilidad...",
            @"menu_ax": @"⚠️ Dar permiso de Accesibilidad...",
            @"chk_enable": @"Activar autocorrección automática al escribir",
            @"chk_abbrev": @"Expandir abreviaturas y atajos personalizados",
            @"chk_login": @"Iniciar automáticamente al encender el Mac",
            @"lbl_lang": @"Idioma del Corrector:",
            @"lbl_last": @"Última corrección: %@  (Retroceso tras espacio deshace)",
            @"menu_last": @"Última: %@",
            @"sec_shortcuts": @"Atajos y Abreviaturas Personalizadas",
            @"col_key": @"Atajo (lo que escribes)",
            @"col_val": @"Reemplazar por",
            @"ph_key": @"Ej: xq",
            @"ph_val": @"Ej: porque",
            @"btn_save": @"Guardar",
            @"btn_remove": @"Eliminar",
            @"lbl_test": @"Prueba aquí mismo (escribe ej: 'informacion tambien '):",
            @"ph_test": @"Escribe aquí con espacios para probar en vivo...",
            @"menu_open_panel": @"⚙️ Abrir Panel de NotionAutocorrect...",
            @"menu_enable": @"Activar Autocorrección",
            @"menu_abbrev": @"Expandir Abreviaturas",
            @"menu_quit": @"Salir de NotionAutocorrect",
            @"menu_close": @"Cerrar Ventana",
            @"menu_edit": @"Editar",
            @"menu_undo": @"Deshacer",
            @"menu_cut": @"Cortar",
            @"menu_copy": @"Copiar",
            @"menu_paste": @"Pegar",
            @"menu_select_all": @"Seleccionar Todo",
            @"undone": @"Deshecho e Ignorado (%@)",
            @"btn_ignored": @"🚫 Palabras Ignoradas (%lu)",
            @"ign_win_title": @"Palabras Ignoradas Automáticamente",
            @"ign_subtitle": @"Las palabras deshechas con Retroceso se guardan aquí y no se vuelven a corregir.",
            @"ign_col": @"Palabra Ignorada",
            @"ign_ph": @"Añadir palabra a ignorar...",
            @"ign_add": @"Añadir",
            @"ign_remove": @"Restaurar Seleccionada",
            @"ign_clear": @"Borrar Todo"
        },
        @"fr": @{
            @"win_title": @"NotionAutocorrect — Panneau de Contrôle",
            @"subtitle": @"Correction automatique native en temps réel pour Notion Desktop (100% Hors ligne)",
            @"auto_lang": @"🌐 Automatique (Détection Intelligente)",
            @"none_yet": @"Aucune pour l'instant",
            @"status_init": @"Statut : Initialisation...",
            @"status_need_ax": @"⚠️ Autorisation d'Accessibilité requise",
            @"status_paused": @"⏸ Correction automatique en pause",
            @"status_ready": @"✅ Tout est prêt ! Actif dans Notion (%@ · %lu raccourcis)",
            @"menu_need_ax": @"Statut : En attente d'Accessibilité",
            @"menu_paused": @"Statut : En pause",
            @"menu_ready": @"Statut : Actif (%@)",
            @"btn_ax": @"Ouvrir Accessibilité...",
            @"menu_ax": @"⚠️ Accorder l'accès Accessibilité...",
            @"chk_enable": @"Activer la correction automatique lors de la frappe",
            @"chk_abbrev": @"Développer les abréviations et raccourcis",
            @"chk_login": @"Démarrer automatiquement à l'ouverture de session",
            @"lbl_lang": @"Langue du correcteur :",
            @"lbl_last": @"Dernière correction : %@  (Retour arrière annule)",
            @"menu_last": @"Dernière : %@",
            @"sec_shortcuts": @"Raccourcis et Abréviations Personnalisés",
            @"col_key": @"Raccourci",
            @"col_val": @"Remplacer par",
            @"ph_key": @"Ex : bcp",
            @"ph_val": @"Ex : beaucoup",
            @"btn_save": @"Enregistrer",
            @"btn_remove": @"Supprimer",
            @"lbl_test": @"Testez ici (tapez ex : 'bcp aujourdhui '):",
            @"ph_test": @"Tapez ici avec des espaces pour tester...",
            @"menu_open_panel": @"⚙️ Ouvrir NotionAutocorrect...",
            @"menu_enable": @"Activer la correction",
            @"menu_abbrev": @"Développer les abréviations",
            @"menu_quit": @"Quitter NotionAutocorrect",
            @"menu_close": @"Fermer la fenêtre",
            @"menu_edit": @"Édition",
            @"menu_undo": @"Annuler",
            @"menu_cut": @"Couper",
            @"menu_copy": @"Copier",
            @"menu_paste": @"Coller",
            @"menu_select_all": @"Tout sélectionner",
            @"undone": @"Annulé et Ignoré (%@)",
            @"btn_ignored": @"🚫 Mots Ignorés (%lu)",
            @"ign_win_title": @"Mots Ignorés Automatiquement",
            @"ign_subtitle": @"Les mots annulés avec Retour arrière sont ajoutés ici et ne seront plus corrigés.",
            @"ign_col": @"Mot Ignoré",
            @"ign_ph": @"Ajouter un mot à ignorer...",
            @"ign_add": @"Ajouter",
            @"ign_remove": @"Restaurer la sélection",
            @"ign_clear": @"Tout effacer"
        }
    };
}

- (NSString *)tr:(NSString *)key {
    NSDictionary *dict = self.uiStrings[self.uiLang] ?: self.uiStrings[@"en"];
    return dict[key] ?: self.uiStrings[@"en"][key] ?: key;
}

- (void)setupSupportedLanguages {
    self.supportedLanguages = @[
        @{@"code": @"auto", @"name": [self tr:@"auto_lang"]},
        @{@"code": @"pt_BR", @"name": @"🇧🇷 Português (Brasil)"},
        @{@"code": @"pt_PT", @"name": @"🇵🇹 Português (Portugal)"},
        @{@"code": @"en_US", @"name": @"🇺🇸 English (US)"},
        @{@"code": @"en_GB", @"name": @"🇬🇧 English (UK)"},
        @{@"code": @"es_ES", @"name": @"🇪🇸 Español"},
        @{@"code": @"fr_FR", @"name": @"🇫🇷 Français"},
        @{@"code": @"de_DE", @"name": @"🇩🇪 Deutsch"},
        @{@"code": @"it_IT", @"name": @"🇮🇹 Italiano"}
    ];
}

- (NSString *)normalizeLanguageTag:(NSString *)raw {
    if (!raw || raw.length == 0) return nil;
    NSString *tag = [[raw stringByReplacingOccurrencesOfString:@"-" withString:@"_"] lowercaseString];
    if ([tag hasPrefix:@"pt_pt"]) return @"pt_PT";
    if ([tag hasPrefix:@"pt"]) return @"pt_BR";
    if ([tag hasPrefix:@"en_gb"]) return @"en_GB";
    if ([tag hasPrefix:@"en"]) return @"en_US";
    if ([tag hasPrefix:@"es"]) return @"es_ES";
    if ([tag hasPrefix:@"fr"]) return @"fr_FR";
    if ([tag hasPrefix:@"de"]) return @"de_DE";
    if ([tag hasPrefix:@"it"]) return @"it_IT";
    return nil;
}

- (NSString *)detectPrimaryLanguageFromSystemAndNotion {
    // 1. Tenta ler o idioma de corretor já configurado no próprio Notion Desktop
    NSString *notionPrefs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Notion/Partitions/notion/Preferences"];
    NSData *data = [NSData dataWithContentsOfFile:notionPrefs];
    if (data) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *dicts = json[@"spellcheck"][@"dictionaries"];
        if ([dicts isKindOfClass:[NSArray class]] && dicts.count > 0) {
            NSString *norm = [self normalizeLanguageTag:dicts[0]];
            if (norm) return norm;
        }
    }

    // 2. Fallback: idiomas preferidos do macOS
    for (NSString *pref in [NSLocale preferredLanguages]) {
        NSString *norm = [self normalizeLanguageTag:pref];
        if (norm) return norm;
    }
    return @"en_US";
}

- (void)loadSystemTextReplacements {
    [self.systemReplacementsMap removeAllObjects];
    CFArrayRef items = CFPreferencesCopyAppValue(CFSTR("NSUserDictionaryReplacementItems"), kCFPreferencesAnyApplication);
    NSArray *arr = (__bridge_transfer NSArray *)items;
    if (![arr isKindOfClass:[NSArray class]]) return;

    for (NSDictionary *item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (![item[@"on"] boolValue]) continue;
        NSString *rep = item[@"replace"];
        NSString *with = item[@"with"];
        if ([rep isKindOfClass:[NSString class]] && [with isKindOfClass:[NSString class]] &&
            rep.length >= 2 && with.length > 0 && ![rep containsString:@" "]) {
            self.systemReplacementsMap[[rep lowercaseString]] = with;
        }
    }
}

- (NSString *)effectiveLanguageForCurrentContext {
    if (![self.currentLanguage isEqualToString:@"auto"]) {
        return self.currentLanguage ?: @"pt_BR";
    }
    if (self.sentenceBuffer.length >= 12) {
        NSSpellChecker *sc = [NSSpellChecker sharedSpellChecker];
        NSOrthography *ortho = nil;
        [sc checkString:self.sentenceBuffer
                  range:NSMakeRange(0, self.sentenceBuffer.length)
                  types:NSTextCheckingTypeOrthography
                options:nil
 inSpellDocumentWithTag:self.spellDocTag
            orthography:&ortho
              wordCount:NULL];
        NSString *detected = [self normalizeLanguageTag:ortho.dominantLanguage];
        if (detected) {
            self.lastActiveLanguage = detected;
            return detected;
        }
    }
    return self.lastActiveLanguage ?: (self.detectedPrimaryLanguage ?: @"pt_BR");
}

- (NSLocale *)currentLocale {
    return [NSLocale localeWithLocaleIdentifier:[self effectiveLanguageForCurrentContext]];
}

- (void)setupDictionaries {
    NSDictionary *ptAbbrev = @{
        @"vc": @"você", @"vcs": @"vocês", @"tb": @"também", @"tbm": @"também",
        @"pq": @"porque", @"qdo": @"quando", @"qnd": @"quando", @"eh": @"é",
        @"msm": @"mesmo", @"hj": @"hoje", @"obg": @"obrigado", @"pfv": @"por favor",
        @"ctz": @"certeza", @"vdd": @"verdade", @"blz": @"beleza", @"flw": @"falou",
        @"vlw": @"valeu", @"msg": @"mensagem"
    };

    NSDictionary *enAbbrev = @{
        @"idk": @"I don't know", @"imo": @"in my opinion", @"tbh": @"to be honest",
        @"btw": @"by the way", @"omw": @"on my way", @"afaik": @"as far as I know",
        @"bc": @"because", @"w/": @"with", @"w/o": @"without", @"tmrw": @"tomorrow"
    };

    NSDictionary *esAbbrev = @{
        @"xq": @"porque", @"pq": @"porque", @"tb": @"también", @"tmb": @"también",
        @"qdo": @"cuando", @"msj": @"mensaje", @"xfa": @"por favor"
    };

    NSDictionary *frAbbrev = @{
        @"bcp": @"beaucoup", @"ajd": @"aujourd'hui", @"tjr": @"toujours",
        @"tjrs": @"toujours", @"pb": @"problème", @"pck": @"parce que"
    };

    self.abbrevByLang = @{
        @"pt_BR": ptAbbrev, @"pt_PT": ptAbbrev,
        @"en_US": enAbbrev, @"en_GB": enAbbrev,
        @"es_ES": esAbbrev, @"fr_FR": frAbbrev,
        @"de_DE": @{}, @"it_IT": @{}
    };

    NSDictionary *ptBuiltin = @{
        @"voce": @"você", @"voces": @"vocês", @"nao": @"não", @"entao": @"então",
        @"tambem": @"também", @"alem": @"além", @"porem": @"porém", @"ja": @"já",
        @"so": @"só", @"ate": @"até", @"apos": @"após", @"tras": @"trás",
        @"tres": @"três", @"mes": @"mês", @"analise": @"análise", @"analises": @"análises",
        @"pratica": @"prática", @"praticas": @"práticas", @"pratico": @"prático",
        @"praticos": @"práticos", @"politica": @"política", @"politicas": @"políticas",
        @"politico": @"político", @"politicos": @"políticos", @"cientifico": @"científico",
        @"cientifica": @"científica", @"cientificos": @"científicos", @"cientificas": @"científicas",
        @"publico": @"público", @"publica": @"pública", @"publicos": @"públicos",
        @"publicas": @"públicas", @"ultimo": @"último", @"ultima": @"última",
        @"ultimos": @"últimos", @"ultimas": @"últimas", @"numero": @"número",
        @"numeros": @"números", @"pagina": @"página", @"paginas": @"páginas",
        @"calculo": @"cálculo", @"calculos": @"cálculos", @"inutil": @"inútil",
        @"inuteis": @"inúteis", @"opniao": @"opinião", @"opiniao": @"opinião",
        @"opinioes": @"opiniões", @"referencia": @"referência", @"referencias": @"referências",
        @"historia": @"história", @"historias": @"histórias", @"memoria": @"memória",
        @"memorias": @"memórias", @"materia": @"matéria", @"materias": @"matérias",
        @"serie": @"série", @"series": @"séries", @"especie": @"espécie",
        @"especies": @"espécies", @"experiencia": @"experiência", @"experiencias": @"experiências",
        @"distancia": @"distância", @"distancias": @"distâncias", @"frequencia": @"frequência",
        @"frequencias": @"frequências", @"consequencia": @"consequência", @"consequencias": @"consequências",
        @"importancia": @"importância", @"presenca": @"presença", @"ausencia": @"ausência",
        @"ciencia": @"ciência", @"ciencias": @"ciências", @"inicio": @"início",
        @"negocio": @"negócio", @"negocios": @"negócios", @"comercio": @"comércio",
        @"industria": @"indústria", @"industrias": @"indústrias", @"proprio": @"próprio",
        @"propria": @"própria", @"proprios": @"próprios", @"proprias": @"próprias",
        @"varios": @"vários", @"varias": @"várias", @"necessario": @"necessário",
        @"necessaria": @"necessária", @"necessarios": @"necessários", @"necessarias": @"necessárias",
        @"contrario": @"contrário", @"salario": @"salário", @"salarios": @"salários",
        @"usuario": @"usuário", @"usuarios": @"usuários", @"critica": @"crítica",
        @"criticas": @"críticas", @"critico": @"crítico", @"criticos": @"críticos",
        @"indice": @"índice", @"indices": @"índices", @"capitulo": @"capítulo",
        @"capitulos": @"capítulos", @"titulo": @"título", @"titulos": @"títulos",
        @"topico": @"tópico", @"topicos": @"tópicos", @"duvida": @"dúvida",
        @"duvidas": @"dúvidas", @"atraves": @"através", @"alguem": @"alguém",
        @"ninguem": @"ninguém", @"parabens": @"parabéns", @"refem": @"refém",
        @"armazem": @"armazém", @"contem": @"contém", @"mantem": @"mantém",
        @"obtem": @"obtém", @"detem": @"detém", @"convem": @"convém",
        @"provem": @"provém", @"intervem": @"intervém", @"estao": @"estão",
        @"sao": @"são", @"irao": @"irão", @"serao": @"serão", @"terao": @"terão",
        @"farao": @"farão", @"poderao": @"poderão", @"deverao": @"deverão",
        @"informacao": @"informação", @"informacoes": @"informações",
        @"situacao": @"situação", @"situacoes": @"situações", @"relacao": @"relação",
        @"relacoes": @"relações", @"solucao": @"solução", @"solucoes": @"soluções",
        @"producao": @"produção", @"producoes": @"produções", @"organizacao": @"organização",
        @"organizacoes": @"organizações", @"globalizacao": @"globalização",
        @"exportacao": @"exportação", @"exportacoes": @"exportações",
        @"importacao": @"importação", @"importacoes": @"importações",
        @"negociacao": @"negociação", @"negociacoes": @"negociações",
        @"operacao": @"operação", @"operacoes": @"operações", @"legislacao": @"legislação",
        @"regulamentacao": @"regulamentação", @"inovacao": @"inovação",
        @"inovacoes": @"inovações", @"comunicacao": @"comunicação", @"educacao": @"educação",
        @"formacao": @"formação", @"participacao": @"participação", @"atencao": @"atenção",
        @"intencao": @"intenção", @"excecao": @"exceção", @"excecoes": @"exceções",
        @"secao": @"seção", @"secoes": @"seções", @"funcao": @"função",
        @"funcoes": @"funções", @"direcao": @"direção", @"opcao": @"opção",
        @"opcoes": @"opções", @"versao": @"versão", @"versoes": @"versões",
        @"visao": @"visão", @"missao": @"missão", @"decisao": @"decisão",
        @"decisoes": @"decisões", @"discussao": @"discussão", @"discussoes": @"discussões",
        @"conclusao": @"conclusão", @"conclusoes": @"conclusões", @"introducao": @"introdução",
        @"avaliacao": @"avaliação", @"avaliacoes": @"avaliações",
        @"apresentacao": @"apresentação", @"apresentacoes": @"apresentações",
        @"administracao": @"administração", @"gestao": @"gestão", @"padrao": @"padrão",
        @"padroes": @"padrões", @"orgao": @"órgão", @"orgaos": @"órgãos",
        @"cidadao": @"cidadão", @"cidadaos": @"cidadãos", @"alemao": @"alemão",
        @"japones": @"japonês", @"ingles": @"inglês", @"frances": @"francês",
        @"portugues": @"português", @"chines": @"chinês", @"economico": @"econômico",
        @"economica": @"econômica", @"economicos": @"econômicos", @"economicas": @"econômicas",
        @"historico": @"histórico", @"historica": @"histórica", @"estrategia": @"estratégia",
        @"estrategias": @"estratégias", @"estrategico": @"estratégico", @"estrategica": @"estratégica",
        @"logistica": @"logística", @"logistico": @"logístico", @"cambio": @"câmbio",
        @"alfandega": @"alfândega", @"mercosul": @"Mercosul",
        @"amanha": @"amanhã", @"irmao": @"irmão", @"irmaos": @"irmãos", @"irma": @"irmã", @"irmas": @"irmãs",
        @"saude": @"saúde", @"musica": @"música", @"musicas": @"músicas", @"epoca": @"época", @"epocas": @"épocas",
        @"maquina": @"máquina", @"maquinas": @"máquinas", @"tecnico": @"técnico", @"tecnica": @"técnica",
        @"tecnicos": @"técnicos", @"tecnicas": @"técnicas", @"basico": @"básico", @"basica": @"básica",
        @"basicos": @"básicos", @"basicas": @"básicas", @"medico": @"médico", @"medica": @"médica",
        @"paises": @"países", @"juridico": @"jurídico", @"juridica": @"jurídica",
        @"automatico": @"automático", @"automatica": @"automática", @"especifico": @"específico",
        @"especifica": @"específica", @"dinamico": @"dinâmico", @"dinamica": @"dinâmica",
        @"classico": @"clássico", @"classica": @"clássica", @"beneficio": @"benefício",
        @"beneficios": @"benefícios", @"prejuizo": @"prejuízo", @"prejuizos": @"prejuízos",
        @"diagnostico": @"diagnóstico", @"proposito": @"propósito", @"veiculo": @"veículo",
        @"veiculos": @"veículos", @"obstaculo": @"obstáculo", @"obstaculos": @"obstáculos",
        @"empresario": @"empresário", @"secretario": @"secretário", @"inventario": @"inventário",
        @"aniversario": @"aniversário", @"vitoria": @"vitória", @"gloria": @"glória",
        @"ferias": @"férias", @"media": @"média", @"medias": @"médias", @"medio": @"médio",
        @"remedio": @"remédio", @"estagio": @"estágio", @"privilegio": @"privilégio",
        @"oficio": @"ofício", @"indicio": @"indício", @"raizes": @"raízes",
        @"republica": @"república", @"uteis": @"úteis", @"moveis": @"móveis",
        @"vinculo": @"vínculo", @"estimulo": @"estímulo", @"vertice": @"vértice",
        @"deficit": @"déficit", @"superavit": @"superávit", @"serio": @"sério",
        @"acao": @"ação", @"acoes": @"ações"
    };

    NSDictionary *enBuiltin = @{
        @"dont": @"don't", @"cant": @"can't", @"wont": @"won't", @"didnt": @"didn't",
        @"doesnt": @"doesn't", @"isnt": @"isn't", @"arent": @"aren't", @"wasnt": @"wasn't",
        @"werent": @"weren't", @"havent": @"haven't", @"hasnt": @"hasn't", @"hadnt": @"hadn't",
        @"wouldnt": @"wouldn't", @"couldnt": @"couldn't", @"shouldnt": @"shouldn't",
        @"im": @"I'm", @"ive": @"I've",
        @"teh": @"the", @"recieve": @"receive", @"seperate": @"separate", @"occured": @"occurred",
        @"definately": @"definitely", @"accomodate": @"accommodate", @"alot": @"a lot"
    };

    NSDictionary *esBuiltin = @{
        @"tambien": @"también", @"ademas": @"además", @"despues": @"después",
        @"informacion": @"información", @"educacion": @"educación", @"solucion": @"solución",
        @"analisis": @"análisis", @"practica": @"práctica", @"politica": @"política",
        @"economico": @"económico", @"historico": @"histórico", @"facil": @"fácil",
        @"dificil": @"difícil", @"util": @"útil", @"pagina": @"página", @"numero": @"número"
    };

    self.builtinByLang = @{
        @"pt_BR": ptBuiltin, @"pt_PT": ptBuiltin,
        @"en_US": enBuiltin, @"en_GB": enBuiltin,
        @"es_ES": esBuiltin,
        @"fr_FR": @{}, @"de_DE": @{}, @"it_IT": @{}
    };
}

- (NSString *)configDirPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".config/notion-autocorrect"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)customDictPath {
    return [[self configDirPath] stringByAppendingPathComponent:@"custom_words.json"];
}

- (NSString *)ignoredWordsPath {
    return [[self configDirPath] stringByAppendingPathComponent:@"ignored_words.json"];
}

- (NSString *)settingsPath {
    return [[self configDirPath] stringByAppendingPathComponent:@"settings.json"];
}

- (void)loadSettingsAndCustomDictionary {
    NSData *sData = [NSData dataWithContentsOfFile:[self settingsPath]];
    if (sData) {
        NSDictionary *sDict = [NSJSONSerialization JSONObjectWithData:sData options:0 error:nil];
        if ([sDict isKindOfClass:[NSDictionary class]]) {
            if (sDict[@"isEnabled"]) self.isEnabled = [sDict[@"isEnabled"] boolValue];
            if (sDict[@"expandAbbreviations"]) self.expandAbbreviations = [sDict[@"expandAbbreviations"] boolValue];
            if ([sDict[@"language"] isKindOfClass:[NSString class]]) self.currentLanguage = sDict[@"language"];
        }
    }

    self.customMap = [NSMutableDictionary dictionary];
    NSString *path = [self customDictPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSDictionary *starter = @{};
        NSData *data = [NSJSONSerialization dataWithJSONObject:starter options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:path atomically:YES];
    }
    NSData *raw = [NSData dataWithContentsOfFile:path];
    if (raw) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in dict) {
                if ([dict[k] isKindOfClass:[NSString class]]) {
                    self.customMap[[k lowercaseString]] = dict[k];
                }
            }
        }
    }
    [self refreshSortedCustomKeys];

    [self.ignoredWordsSet removeAllObjects];
    NSData *igData = [NSData dataWithContentsOfFile:[self ignoredWordsPath]];
    if (igData) {
        NSArray *igArr = [NSJSONSerialization JSONObjectWithData:igData options:0 error:nil];
        if ([igArr isKindOfClass:[NSArray class]]) {
            for (NSString *w in igArr) {
                if ([w isKindOfClass:[NSString class]] && w.length > 0) {
                    [self.ignoredWordsSet addObject:[w lowercaseString]];
                }
            }
        }
    }
    [self refreshSortedIgnoredWords];
}

- (void)saveSettings {
    NSDictionary *sDict = @{
        @"isEnabled": @(self.isEnabled),
        @"expandAbbreviations": @(self.expandAbbreviations),
        @"language": self.currentLanguage ?: @"pt_BR"
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:sDict options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self settingsPath] atomically:YES];
}

- (void)saveCustomDictionary {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.customMap options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self customDictPath] atomically:YES];
    [self refreshSortedCustomKeys];
    if (self.shortcutsTable) {
        [self.shortcutsTable reloadData];
    }
}

- (void)refreshSortedCustomKeys {
    [self.sortedCustomKeys setArray:[[self.customMap allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]];
}

- (void)refreshSortedIgnoredWords {
    [self.sortedIgnoredWords setArray:[[self.ignoredWordsSet allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]];
}

- (void)saveIgnoredWords {
    [self refreshSortedIgnoredWords];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.sortedIgnoredWords options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self ignoredWordsPath] atomically:YES];
    if (self.ignoredTable) {
        [self.ignoredTable reloadData];
    }
    [self updateStatusUI];
}

- (void)setupMainMenu {
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];

    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *openPanelItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_open_panel"]
                                                           action:@selector(showControlWindow:)
                                                    keyEquivalent:@"o"];
    openPanelItem.target = self;
    [appMenu addItem:openPanelItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_close"]
                                                       action:@selector(performClose:)
                                                keyEquivalent:@"w"];
    [appMenu addItem:closeItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_quit"]
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [appMenuItem setSubmenu:appMenu];

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:[self tr:@"menu_edit"]];
    [editMenu addItemWithTitle:[self tr:@"menu_undo"] action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:[self tr:@"menu_cut"] action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:[self tr:@"menu_copy"] action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:[self tr:@"menu_paste"] action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:[self tr:@"menu_select_all"] action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
}

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"NotionAutocorrect"];

    NSMenuItem *openWinItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_open_panel"]
                                                         action:@selector(showControlWindow:)
                                                  keyEquivalent:@""];
    openWinItem.target = self;
    [menu addItem:openWinItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"status_init"] action:nil keyEquivalent:@""];
    [menu addItem:self.statusMenuItem];

    self.lastCorrectionMenuItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:[self tr:@"menu_last"], [self tr:@"none_yet"]] action:nil keyEquivalent:@""];
    [menu addItem:self.lastCorrectionMenuItem];

    self.accessibilityMenuItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_ax"]
                                                            action:@selector(openAccessibilitySettings:)
                                                     keyEquivalent:@""];
    self.accessibilityMenuItem.target = self;
    [menu addItem:self.accessibilityMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.enableMenuItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_enable"]
                                                     action:@selector(toggleEnabled:)
                                              keyEquivalent:@""];
    self.enableMenuItem.target = self;
    [menu addItem:self.enableMenuItem];

    self.abbrevMenuItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_abbrev"]
                                                     action:@selector(toggleAbbreviations:)
                                              keyEquivalent:@""];
    self.abbrevMenuItem.target = self;
    [menu addItem:self.abbrevMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[self tr:@"menu_quit"]
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self updateStatusUI];
}

- (NSTextField *)makeLabel:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold size:(CGFloat)size {
    NSTextField *lbl = [[NSTextField alloc] initWithFrame:frame];
    lbl.stringValue = text;
    lbl.bezeled = NO;
    lbl.drawsBackground = NO;
    lbl.editable = NO;
    lbl.selectable = NO;
    lbl.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    return lbl;
}

- (void)buildMainWindow {
    NSRect frame = NSMakeRect(0, 0, 560, 586);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:style
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.mainWindow.title = [self tr:@"win_title"];
    self.mainWindow.releasedWhenClosed = NO;
    self.mainWindow.delegate = self;
    [self.mainWindow center];

    NSView *cv = self.mainWindow.contentView;

    // Título e subtítulo
    [cv addSubview:[self makeLabel:@"NotionAutocorrect" frame:NSMakeRect(24, 538, 512, 28) bold:YES size:20]];
    NSTextField *sub = [self makeLabel:[self tr:@"subtitle"]
                                 frame:NSMakeRect(24, 516, 512, 20) bold:NO size:12.5];
    sub.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:sub];

    // Caixa de Status + Permissão
    NSBox *statusBox = [[NSBox alloc] initWithFrame:NSMakeRect(24, 446, 512, 60)];
    statusBox.titlePosition = NSNoTitle;
    [cv addSubview:statusBox];

    self.statusBannerLabel = [self makeLabel:[self tr:@"status_init"] frame:NSMakeRect(14, 18, 480, 22) bold:YES size:13];
    [statusBox.contentView addSubview:self.statusBannerLabel];

    self.openAccessBtn = [[NSButton alloc] initWithFrame:NSMakeRect(326, 13, 170, 30)];
    self.openAccessBtn.bezelStyle = NSBezelStyleRounded;
    self.openAccessBtn.title = [self tr:@"btn_ax"];
    self.openAccessBtn.target = self;
    self.openAccessBtn.action = @selector(openAccessibilitySettings:);
    [statusBox.contentView addSubview:self.openAccessBtn];

    // Opções Gerais e Idioma
    self.enableCheckbox = [NSButton checkboxWithTitle:[self tr:@"chk_enable"]
                                               target:self
                                               action:@selector(toggleEnabled:)];
    self.enableCheckbox.frame = NSMakeRect(24, 412, 360, 22);
    [cv addSubview:self.enableCheckbox];

    self.abbrevCheckbox = [NSButton checkboxWithTitle:[self tr:@"chk_abbrev"]
                                               target:self
                                               action:@selector(toggleAbbreviations:)];
    self.abbrevCheckbox.frame = NSMakeRect(24, 386, 380, 22);
    [cv addSubview:self.abbrevCheckbox];

    self.launchAtLoginCheckbox = [NSButton checkboxWithTitle:[self tr:@"chk_login"]
                                                      target:self
                                                      action:@selector(toggleLaunchAtLogin:)];
    self.launchAtLoginCheckbox.frame = NSMakeRect(24, 360, 380, 22);
    self.launchAtLoginCheckbox.state = [self isLaunchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.launchAtLoginCheckbox];

    [cv addSubview:[self makeLabel:[self tr:@"lbl_lang"] frame:NSMakeRect(24, 324, 155, 22) bold:YES size:13]];

    self.languagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(182, 321, 250, 28) pullsDown:NO];
    for (NSDictionary *lang in self.supportedLanguages) {
        [self.languagePopup addItemWithTitle:lang[@"name"]];
        self.languagePopup.lastItem.representedObject = lang[@"code"];
    }
    self.languagePopup.target = self;
    self.languagePopup.action = @selector(languageChanged:);
    [cv addSubview:self.languagePopup];

    self.lastCorrLabel = [self makeLabel:[NSString stringWithFormat:[self tr:@"lbl_last"], [self tr:@"none_yet"]]
                                   frame:NSMakeRect(24, 294, 512, 20) bold:NO size:12];
    self.lastCorrLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.lastCorrLabel];

    // Seção: Gerenciador de Atalhos / Gírias + Botão de Palavras Ignoradas
    [cv addSubview:[self makeLabel:[self tr:@"sec_shortcuts"] frame:NSMakeRect(24, 260, 320, 22) bold:YES size:14]];

    self.ignoredWordsBtn = [[NSButton alloc] initWithFrame:NSMakeRect(346, 256, 190, 28)];
    self.ignoredWordsBtn.bezelStyle = NSBezelStyleRounded;
    self.ignoredWordsBtn.title = [NSString stringWithFormat:[self tr:@"btn_ignored"], (unsigned long)self.ignoredWordsSet.count];
    self.ignoredWordsBtn.target = self;
    self.ignoredWordsBtn.action = @selector(showIgnoredWordsWindow:);
    [cv addSubview:self.ignoredWordsBtn];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 130, 512, 124)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    self.shortcutsTable = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn *colKey = [[NSTableColumn alloc] initWithIdentifier:@"key"];
    colKey.title = [self tr:@"col_key"];
    colKey.width = 180;
    [self.shortcutsTable addTableColumn:colKey];

    NSTableColumn *colVal = [[NSTableColumn alloc] initWithIdentifier:@"val"];
    colVal.title = [self tr:@"col_val"];
    colVal.width = 310;
    [self.shortcutsTable addTableColumn:colVal];

    self.shortcutsTable.dataSource = self;
    self.shortcutsTable.delegate = self;
    self.shortcutsTable.usesAlternatingRowBackgroundColors = YES;
    scrollView.documentView = self.shortcutsTable;
    [cv addSubview:scrollView];

    // Campos para adicionar/remover atalho
    self.shortcutKeyInput = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 94, 120, 26)];
    self.shortcutKeyInput.placeholderString = [self tr:@"ph_key"];
    [cv addSubview:self.shortcutKeyInput];

    self.shortcutValInput = [[NSTextField alloc] initWithFrame:NSMakeRect(152, 94, 190, 26)];
    self.shortcutValInput.placeholderString = [self tr:@"ph_val"];
    [cv addSubview:self.shortcutValInput];

    NSButton *addBtn = [[NSButton alloc] initWithFrame:NSMakeRect(350, 92, 90, 30)];
    addBtn.bezelStyle = NSBezelStyleRounded;
    addBtn.title = [self tr:@"btn_save"];
    addBtn.target = self;
    addBtn.action = @selector(addOrUpdateShortcut:);
    [cv addSubview:addBtn];

    NSButton *removeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(444, 92, 92, 30)];
    removeBtn.bezelStyle = NSBezelStyleRounded;
    removeBtn.title = [self tr:@"btn_remove"];
    removeBtn.target = self;
    removeBtn.action = @selector(removeSelectedShortcut:);
    [cv addSubview:removeBtn];

    // Campo de teste ao vivo dentro do próprio painel
    [cv addSubview:[self makeLabel:[self tr:@"lbl_test"]
                             frame:NSMakeRect(24, 56, 512, 20) bold:YES size:12.5]];

    self.testInputField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 22, 512, 28)];
    self.testInputField.placeholderString = [self tr:@"ph_test"];
    [cv addSubview:self.testInputField];

    [self syncLanguagePopupSelection];
    [self updateStatusUI];
}

- (void)syncLanguagePopupSelection {
    for (NSInteger i = 0; i < self.languagePopup.numberOfItems; i++) {
        NSMenuItem *item = [self.languagePopup itemAtIndex:i];
        if ([item.representedObject isEqualToString:self.currentLanguage]) {
            [self.languagePopup selectItemAtIndex:i];
            break;
        }
    }
}

- (void)showControlWindow:(id)sender {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWindow makeKeyAndOrderFront:nil];
    [self updateStatusUI];
}

- (void)languageChanged:(id)sender {
    NSString *code = self.languagePopup.selectedItem.representedObject;
    if (code) {
        self.currentLanguage = code;
        [self saveSettings];
        [self resetBuffer];
        [self updateStatusUI];
    }
}

- (void)addOrUpdateShortcut:(id)sender {
    NSString *k = [[self.shortcutKeyInput.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSString *v = [self.shortcutValInput.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (k.length == 0 || v.length == 0) return;

    self.customMap[k] = v;
    self.shortcutKeyInput.stringValue = @"";
    self.shortcutValInput.stringValue = @"";
    [self saveCustomDictionary];
}

- (void)removeSelectedShortcut:(id)sender {
    NSInteger row = self.shortcutsTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.sortedCustomKeys.count) {
        NSString *key = self.sortedCustomKeys[row];
        [self.customMap removeObjectForKey:key];
        [self saveCustomDictionary];
    }
}

- (void)showIgnoredWordsWindow:(id)sender {
    if (!self.ignoredWordsWindow) {
        NSRect frame = NSMakeRect(0, 0, 420, 360);
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
        self.ignoredWordsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                              styleMask:style
                                                                backing:NSBackingStoreBuffered
                                                                  defer:NO];
        self.ignoredWordsWindow.title = [self tr:@"ign_win_title"];
        self.ignoredWordsWindow.releasedWhenClosed = NO;
        [self.ignoredWordsWindow center];

        NSView *cv = self.ignoredWordsWindow.contentView;
        NSTextField *sub = [self makeLabel:[self tr:@"ign_subtitle"]
                                     frame:NSMakeRect(20, 310, 380, 34) bold:NO size:12];
        sub.textColor = [NSColor secondaryLabelColor];
        sub.usesSingleLineMode = NO;
        sub.cell.wraps = YES;
        [cv addSubview:sub];

        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 70, 380, 232)];
        sv.hasVerticalScroller = YES;
        sv.borderType = NSBezelBorder;

        self.ignoredTable = [[NSTableView alloc] initWithFrame:sv.bounds];
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"word"];
        col.title = [self tr:@"ign_col"];
        col.width = 355;
        [self.ignoredTable addTableColumn:col];
        self.ignoredTable.dataSource = self;
        self.ignoredTable.delegate = self;
        self.ignoredTable.usesAlternatingRowBackgroundColors = YES;
        sv.documentView = self.ignoredTable;
        [cv addSubview:sv];

        self.ignoredWordInput = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 24, 140, 26)];
        self.ignoredWordInput.placeholderString = [self tr:@"ign_ph"];
        [cv addSubview:self.ignoredWordInput];

        NSButton *addBtn = [[NSButton alloc] initWithFrame:NSMakeRect(166, 22, 68, 30)];
        addBtn.bezelStyle = NSBezelStyleRounded;
        addBtn.title = [self tr:@"ign_add"];
        addBtn.target = self;
        addBtn.action = @selector(addIgnoredWordAction:);
        [cv addSubview:addBtn];

        NSButton *remBtn = [[NSButton alloc] initWithFrame:NSMakeRect(236, 22, 92, 30)];
        remBtn.bezelStyle = NSBezelStyleRounded;
        remBtn.title = [self tr:@"btn_remove"];
        remBtn.target = self;
        remBtn.action = @selector(removeSelectedIgnoredWord:);
        [cv addSubview:remBtn];

        NSButton *clrBtn = [[NSButton alloc] initWithFrame:NSMakeRect(330, 22, 74, 30)];
        clrBtn.bezelStyle = NSBezelStyleRounded;
        clrBtn.title = [self tr:@"ign_clear"];
        clrBtn.target = self;
        clrBtn.action = @selector(clearAllIgnoredWords:);
        [cv addSubview:clrBtn];
    }
    [self.ignoredTable reloadData];
    [NSApp activateIgnoringOtherApps:YES];
    [self.ignoredWordsWindow makeKeyAndOrderFront:nil];
}

- (void)addIgnoredWordAction:(id)sender {
    NSString *w = [[self.ignoredWordInput.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (w.length == 0) return;
    [self.ignoredWordsSet addObject:w];
    self.ignoredWordInput.stringValue = @"";
    [self saveIgnoredWords];
}

- (void)removeSelectedIgnoredWord:(id)sender {
    NSInteger row = self.ignoredTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.sortedIgnoredWords.count) {
        NSString *w = self.sortedIgnoredWords[row];
        [self.ignoredWordsSet removeObject:w];
        [self saveIgnoredWords];
    }
}

- (void)clearAllIgnoredWords:(id)sender {
    [self.ignoredWordsSet removeAllObjects];
    [self saveIgnoredWords];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.ignoredTable) {
        return self.sortedIgnoredWords.count;
    }
    return self.sortedCustomKeys.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.ignoredTable) {
        if (row < 0 || row >= (NSInteger)self.sortedIgnoredWords.count) return @"";
        return self.sortedIgnoredWords[row];
    }
    if (row < 0 || row >= (NSInteger)self.sortedCustomKeys.count) return @"";
    NSString *key = self.sortedCustomKeys[row];
    if ([tableColumn.identifier isEqualToString:@"key"]) {
        return key;
    }
    return self.customMap[key] ?: @"";
}

- (void)updateStatusUI {
    BOOL trusted = AXIsProcessTrusted() && (self.eventTap != NULL);
    if (!AXIsProcessTrusted()) {
        self.statusItem.button.title = @"Aa⚠️";
        self.statusMenuItem.title = [self tr:@"menu_need_ax"];
        self.accessibilityMenuItem.hidden = NO;
        self.statusBannerLabel.frame = NSMakeRect(14, 18, 308, 22);
        self.statusBannerLabel.stringValue = [self tr:@"status_need_ax"];
        self.statusBannerLabel.textColor = [NSColor systemOrangeColor];
        self.openAccessBtn.hidden = NO;
    } else if (!self.isEnabled) {
        self.statusItem.button.title = @"Aa⏸";
        self.statusMenuItem.title = [self tr:@"menu_paused"];
        self.accessibilityMenuItem.hidden = YES;
        self.statusBannerLabel.frame = NSMakeRect(14, 18, 480, 22);
        self.statusBannerLabel.stringValue = [self tr:@"status_paused"];
        self.statusBannerLabel.textColor = [NSColor secondaryLabelColor];
        self.openAccessBtn.hidden = YES;
    } else if (trusted) {
        NSString *activeLang = [self effectiveLanguageForCurrentContext];
        NSString *langDesc = [self.currentLanguage isEqualToString:@"auto"]
            ? [NSString stringWithFormat:@"Auto · %@", activeLang]
            : activeLang;
        self.statusItem.button.title = @"Aa✓";
        self.statusMenuItem.title = [NSString stringWithFormat:[self tr:@"menu_ready"], langDesc];
        self.accessibilityMenuItem.hidden = YES;
        self.statusBannerLabel.frame = NSMakeRect(14, 18, 480, 22);
        self.statusBannerLabel.stringValue = [NSString stringWithFormat:[self tr:@"status_ready"], langDesc, (unsigned long)self.systemReplacementsMap.count];
        self.statusBannerLabel.textColor = [NSColor systemGreenColor];
        self.openAccessBtn.hidden = YES;
    }

    self.enableMenuItem.state = self.isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.abbrevMenuItem.state = self.expandAbbreviations ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.enableCheckbox) self.enableCheckbox.state = self.isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.abbrevCheckbox) self.abbrevCheckbox.state = self.expandAbbreviations ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.ignoredWordsBtn) {
        self.ignoredWordsBtn.title = [NSString stringWithFormat:[self tr:@"btn_ignored"], (unsigned long)self.ignoredWordsSet.count];
    }

    self.lastCorrectionMenuItem.title = [NSString stringWithFormat:[self tr:@"menu_last"], self.lastCorrectionDisplay];
    if (self.lastCorrLabel) {
        self.lastCorrLabel.stringValue = [NSString stringWithFormat:[self tr:@"lbl_last"], self.lastCorrectionDisplay];
    }
    [self writeRuntimeStatusFile];
}

- (void)writeRuntimeStatusFile {
    NSDictionary *status = @{
        @"trusted": @(AXIsProcessTrusted()),
        @"eventTapActive": @(self.eventTap != NULL),
        @"isEnabled": @(self.isEnabled),
        @"language": [self effectiveLanguageForCurrentContext] ?: @"pt_BR",
        @"lastCorrection": self.lastCorrectionDisplay ?: @"",
        @"testFieldValue": self.testInputField.stringValue ?: @""
    };
    NSString *path = [[self configDirPath] stringByAppendingPathComponent:@"status.json"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}

- (void)runLiveSelfTestNotification:(NSNotification *)note {
    if (!AXIsProcessTrusted() || !self.eventTap) {
        [self writeRuntimeStatusFile];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        [self.mainWindow makeKeyAndOrderFront:nil];
        self.testInputField.stringValue = @"";
        [self.mainWindow makeFirstResponder:self.testInputField];
        NSText *editor = [self.testInputField currentEditor];
        if ([editor isKindOfClass:[NSTextView class]]) {
            ((NSTextView *)editor).automaticSpellingCorrectionEnabled = NO;
        }
        [self resetSentenceAndWordBuffer];

        NSString *sample = @"vc nao imagina como essa informacao eh util na facukdade ";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            usleep(150000);
            CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
            for (NSUInteger i = 0; i < sample.length; i++) {
                unichar ch = [sample characterAtIndex:i];
                CGKeyCode kc = (ch == ' ') ? kKeyCodeSpace : 0;
                CGEventRef kd = CGEventCreateKeyboardEvent(src, kc, true);
                CGEventRef ku = CGEventCreateKeyboardEvent(src, kc, false);
                CGEventSetFlags(kd, 0);
                CGEventSetFlags(ku, 0);
                CGEventKeyboardSetUnicodeString(kd, 1, &ch);
                CGEventKeyboardSetUnicodeString(ku, 1, &ch);
                CGEventPost(kCGHIDEventTap, kd);
                CGEventPost(kCGHIDEventTap, ku);
                CFRelease(kd);
                CFRelease(ku);
                usleep(25000);
            }
            if (src) CFRelease(src);
            usleep(300000);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self writeRuntimeStatusFile];
            });
        });
    });
}

- (void)openAccessibilitySettings:(id)sender {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)toggleEnabled:(id)sender {
    self.isEnabled = !self.isEnabled;
    [self saveSettings];
    [self resetBuffer];
    [self updateStatusUI];
}

- (void)toggleAbbreviations:(id)sender {
    self.expandAbbreviations = !self.expandAbbreviations;
    [self saveSettings];
    [self updateStatusUI];
}

- (NSString *)launchAgentPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"com.bernardo.NotionAutocorrect.plist"];
}

- (BOOL)isLaunchAtLoginEnabled {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
}

- (void)toggleLaunchAtLogin:(id)sender {
    NSString *path = [self launchAgentPath];
    if ([self isLaunchAtLoginEnabled]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    } else {
        NSString *execPath = [[NSBundle mainBundle] executablePath] ?: @"/Applications/NotionAutocorrect.app/Contents/MacOS/NotionAutocorrect";
        NSDictionary *plist = @{
            @"Label": @"com.bernardo.NotionAutocorrect",
            @"ProgramArguments": @[execPath, @"--background"],
            @"RunAtLoad": @YES,
            @"KeepAlive": @{@"SuccessfulExit": @NO}
        };
        [plist writeToFile:path atomically:YES];
    }
    if (self.launchAtLoginCheckbox) {
        self.launchAtLoginCheckbox.state = [self isLaunchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)registerWorkspaceNotifications {
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:self
           selector:@selector(activeAppDidChange:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];
}

- (void)activeAppDidChange:(NSNotification *)note {
    [self resetSentenceAndWordBuffer];
}

- (BOOL)isTargetAppFrontmost {
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    NSString *bid = front.bundleIdentifier;
    if ([bid isEqualToString:@"notion.id"]) {
        return YES;
    }
    // Permite testar dentro do campo "Teste aqui mesmo" da própria janela do NotionAutocorrect
    if ([bid isEqualToString:@"com.bernardo.NotionAutocorrect"] &&
        self.mainWindow != nil &&
        self.mainWindow.isVisible &&
        self.mainWindow.isKeyWindow &&
        self.testInputField != nil &&
        [self.testInputField currentEditor] != nil) {
        return YES;
    }
    return NO;
}

- (void)resetBuffer {
    [self.wordBuffer setString:@""];
    self.skipCurrentWord = NO;
    self.wordHasTrailingDot = NO;
    self.canUndoLastCorrection = NO;
    self.deadKeyState = 0;
}

- (void)resetSentenceAndWordBuffer {
    [self resetBuffer];
    [self.sentenceBuffer setString:@""];
}

- (void)checkPermissionsPeriodic {
    BOOL trustedNow = AXIsProcessTrusted();
    if (!self.eventTap && trustedNow) {
        [self startEventTapIfTrusted:NO];
    }
    if (trustedNow != self.lastKnownTrusted) {
        self.lastKnownTrusted = trustedNow;
        [self updateStatusUI];
    }
}

- (void)startEventTapIfTrusted:(BOOL)promptIfNeeded {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @(promptIfNeeded)};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (!trusted) {
        [self updateStatusUI];
        return;
    }

    if (self.eventTap) {
        return;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventRightMouseDown);

    self.eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionDefault,
                                     mask,
                                     EventTapCallback,
                                     (__bridge void *)self);
    if (self.eventTap) {
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), self.runLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(self.eventTap, true);
    }
    [self updateStatusUI];
}

- (NSString *)applyCaseOfOriginal:(NSString *)orig toCorrection:(NSString *)corr {
    if (orig.length == 0 || corr.length == 0) return corr;

    // Não altera capitalização de e-mails ou URLs (ex.: user@example.com, https://...)
    if ([corr containsString:@"@"] || [corr containsString:@"://"]) {
        return corr;
    }

    NSLocale *loc = [self currentLocale];
    NSString *upperOrig = [orig uppercaseStringWithLocale:loc];
    NSString *lowerOrig = [orig lowercaseStringWithLocale:loc];
    if (orig.length >= 2 && [orig isEqualToString:upperOrig] && ![orig isEqualToString:lowerOrig]) {
        return [corr uppercaseStringWithLocale:loc];
    }

    unichar firstOrig = [orig characterAtIndex:0];
    if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:firstOrig]) {
        NSString *firstCorrUpper = [[corr substringToIndex:1] uppercaseStringWithLocale:loc];
        return [firstCorrUpper stringByAppendingString:[corr substringFromIndex:1]];
    }

    return corr;
}

- (NSUInteger)portugueseVowelAccentCount:(NSString *)word {
    NSCharacterSet *accents = [NSCharacterSet characterSetWithCharactersInString:@"áéíóúâêôãõàÁÉÍÓÚÂÊÔÃÕÀ"];
    NSUInteger cnt = 0;
    for (NSUInteger i = 0; i < word.length; i++) {
        if ([accents characterIsMember:[word characterAtIndex:i]]) cnt++;
    }
    return cnt;
}

- (NSUInteger)damerauLevenshteinDistance:(NSString *)s1 and:(NSString *)s2 {
    NSUInteger n = s1.length, m = s2.length;
    if (n == 0) return m;
    if (m == 0) return n;
    if (n > 40 || m > 40) return 99;

    NSUInteger d[42][42];
    for (NSUInteger i = 0; i <= n; i++) d[i][0] = i;
    for (NSUInteger j = 0; j <= m; j++) d[0][j] = j;

    for (NSUInteger i = 1; i <= n; i++) {
        unichar c1 = [s1 characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= m; j++) {
            unichar c2 = [s2 characterAtIndex:j - 1];
            NSUInteger cost = (c1 == c2) ? 0 : 1;
            NSUInteger del = d[i - 1][j] + 1;
            NSUInteger ins = d[i][j - 1] + 1;
            NSUInteger sub = d[i - 1][j - 1] + cost;
            NSUInteger best = MIN(del, MIN(ins, sub));
            if (i > 1 && j > 1 &&
                c1 == [s2 characterAtIndex:j - 2] &&
                [s1 characterAtIndex:i - 2] == c2) {
                best = MIN(best, d[i - 2][j - 2] + 1);
            }
            d[i][j] = best;
        }
    }
    return d[n][m];
}

- (NSString *)correctionForWord:(NSString *)word {
    if (word.length < 2 || word.length > 35) return nil;

    NSString *lang = [self effectiveLanguageForCurrentContext];
    NSLocale *loc = [NSLocale localeWithLocaleIdentifier:lang];
    NSString *lower = [word lowercaseStringWithLocale:loc];

    if ([self.ignoredWordsSet containsObject:lower]) {
        return nil;
    }

    if ([self.ignoredOnceWords containsObject:lower]) {
        [self.ignoredOnceWords removeObject:lower];
        return nil;
    }

    // 1. Atalhos personalizados do usuário no app
    if (self.expandAbbreviations && self.customMap[lower]) {
        NSString *target = self.customMap[lower];
        if (![target isEqualToString:word]) {
            return [self applyCaseOfOriginal:word toCorrection:target];
        }
    }

    // 2. Substituições de Texto nativas do macOS (Ajustes do Sistema / iCloud)
    if (self.expandAbbreviations && self.systemReplacementsMap[lower]) {
        NSString *target = self.systemReplacementsMap[lower];
        if (![target isEqualToString:word]) {
            return [self applyCaseOfOriginal:word toCorrection:target];
        }
    }

    // 3. Abreviações do idioma selecionado
    NSDictionary *langAbbrev = self.abbrevByLang[lang];
    if (self.expandAbbreviations && langAbbrev[lower]) {
        return [self applyCaseOfOriginal:word toCorrection:langAbbrev[lower]];
    }

    // 4. Mapa nativo de acentuação/contrações do idioma selecionado
    NSDictionary *langBuiltin = self.builtinByLang[lang];
    if (langBuiltin[lower]) {
        return [self applyCaseOfOriginal:word toCorrection:langBuiltin[lower]];
    }

    // Preserva siglas em MAIÚSCULAS (USP, PIB, ONU, TCC, ABNT, USA, API)
    NSString *upper = [word uppercaseStringWithLocale:loc];
    if ([word isEqualToString:upper]) {
        return nil;
    }

    if (word.length <= 3) {
        return nil;
    }

    // 5. Motor oficial da Apple: NSSpellChecker no idioma selecionado
    NSSpellChecker *sc = [NSSpellChecker sharedSpellChecker];
    NSRange fullRange = NSMakeRange(0, word.length);
    NSRange misspelled = [sc checkSpellingOfString:word
                                        startingAt:0
                                          language:lang
                                              wrap:NO
                            inSpellDocumentWithTag:self.spellDocTag
                                         wordCount:NULL];

    if (misspelled.location == NSNotFound) {
        return nil;
    }

    NSString *foldedWord = [word stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch)
                                                     locale:loc];
    BOOL isPortuguese = [lang hasPrefix:@"pt"];

    NSArray<NSString *> *guesses = [sc guessesForWordRange:fullRange
                                                  inString:word
                                                  language:lang
                                    inSpellDocumentWithTag:self.spellDocTag];

    // 5a. Prioridade máxima: sugestão real do dicionário cuja base sem acento/cedilha é idêntica!
    // (Exige que adicione acento/cedilha real e, em português, no máximo 1 vogal acentuada para bloquear "aprensêntacão")
    for (NSString *g in guesses) {
        if (isPortuguese && ([g containsString:@"ü"] || [self portugueseVowelAccentCount:g] > 1)) continue;
        NSString *lowerG = [g lowercaseStringWithLocale:loc];
        if ([lowerG isEqualToString:lower]) continue; // Ignora mudança apenas de maiúscula ("universidad" -> "Universidad")
        NSString *foldedG = [g stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch)
                                                   locale:loc];
        if ([foldedG isEqualToString:foldedWord] && ![g isEqualToString:word]) {
            return [self applyCaseOfOriginal:word toCorrection:lowerG];
        }
    }

    NSString *corr = [sc correctionForWordRange:fullRange
                                       inString:word
                                       language:lang
                         inSpellDocumentWithTag:self.spellDocTag];

    // Valida se corr é uma palavra real (e não uma síntese inválida como "aprensêntacão")
    if (corr && ![corr isEqualToString:word] && ![corr containsString:@" "] && ![corr containsString:@"-"] &&
        !(isPortuguese && ([corr containsString:@"ü"] || [self portugueseVowelAccentCount:corr] > 1))) {
        BOOL corrIsValid = [guesses containsObject:corr];
        if (!corrIsValid) {
            NSRange checkCorr = [sc checkSpellingOfString:corr
                                               startingAt:0
                                                 language:lang
                                                     wrap:NO
                                   inSpellDocumentWithTag:self.spellDocTag
                                                wordCount:NULL];
            corrIsValid = (checkCorr.location == NSNotFound);
        }
        if (corrIsValid) {
            return [self applyCaseOfOriginal:word toCorrection:corr];
        }
    }

    // 5b. Fallback inteligente usando guesses[0] quando correctionForWordRange retorna nil ou inválido
    // (ex.: "universidad" -> "universidade", "aprensentacao" -> "apresentação")
    for (NSString *g in guesses) {
        if ([g containsString:@" "] || [g containsString:@"-"] || (isPortuguese && [g containsString:@"ü"])) continue;
        NSString *foldedG = [g stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch)
                                                   locale:loc];
        NSUInteger dist = [self damerauLevenshteinDistance:foldedWord and:foldedG];
        NSUInteger maxAllowed = (word.length >= 6) ? 2 : 1;
        if (dist <= maxAllowed && ![g isEqualToString:word]) {
            NSString *lowerG = [g lowercaseStringWithLocale:loc];
            return [self applyCaseOfOriginal:word toCorrection:lowerG];
        }
        break; // Avalia apenas a melhor sugestão válida do topo
    }

    return nil;
}

- (void)sendBackspaces:(NSUInteger)count thenString:(NSString *)text {
    [self sendBackspaces:count thenString:text thenKeyCode:0];
}

- (void)sendBackspaces:(NSUInteger)count thenString:(NSString *)text thenKeyCode:(CGKeyCode)trailingKeyCode {
    atomic_fetch_add(&gActiveReplacementsCount, 1);
    dispatch_async(self.sendQueue, ^{
        CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
        for (NSUInteger i = 0; i < count; i++) {
            CGEventRef kd = CGEventCreateKeyboardEvent(src, kKeyCodeBackspace, true);
            CGEventRef ku = CGEventCreateKeyboardEvent(src, kKeyCodeBackspace, false);
            CGEventSetFlags(kd, 0);
            CGEventSetFlags(ku, 0);
            CGEventSetIntegerValueField(kd, kCGEventSourceUserData, kSyntheticEventMagic);
            CGEventSetIntegerValueField(ku, kCGEventSourceUserData, kSyntheticEventMagic);
            CGEventPost(kCGHIDEventTap, kd);
            CGEventPost(kCGHIDEventTap, ku);
            CFRelease(kd);
            CFRelease(ku);
            usleep(800);
        }

        if (text.length > 0) {
            NSUInteger idx = 0;
            while (idx < text.length) {
                NSRange seq = [text rangeOfComposedCharacterSequenceAtIndex:idx];
                if (seq.length > 0 && seq.length <= 16) {
                    UniChar buf[16];
                    [text getCharacters:buf range:seq];
                    CGEventRef kd = CGEventCreateKeyboardEvent(src, 0, true);
                    CGEventRef ku = CGEventCreateKeyboardEvent(src, 0, false);
                    CGEventSetFlags(kd, 0);
                    CGEventSetFlags(ku, 0);
                    CGEventKeyboardSetUnicodeString(kd, seq.length, buf);
                    CGEventKeyboardSetUnicodeString(ku, seq.length, buf);
                    CGEventSetIntegerValueField(kd, kCGEventSourceUserData, kSyntheticEventMagic);
                    CGEventSetIntegerValueField(ku, kCGEventSourceUserData, kSyntheticEventMagic);
                    CGEventPost(kCGHIDEventTap, kd);
                    CGEventPost(kCGHIDEventTap, ku);
                    CFRelease(kd);
                    CFRelease(ku);
                    usleep(800);
                }
                idx = NSMaxRange(seq);
            }
        }

        if (trailingKeyCode != 0) {
            CGEventRef kd = CGEventCreateKeyboardEvent(src, trailingKeyCode, true);
            CGEventRef ku = CGEventCreateKeyboardEvent(src, trailingKeyCode, false);
            CGEventSetFlags(kd, 0);
            CGEventSetFlags(ku, 0);
            CGEventSetIntegerValueField(kd, kCGEventSourceUserData, kSyntheticEventMagic);
            CGEventSetIntegerValueField(ku, kCGEventSourceUserData, kSyntheticEventMagic);
            CGEventPost(kCGHIDEventTap, kd);
            CGEventPost(kCGHIDEventTap, ku);
            CFRelease(kd);
            CFRelease(ku);
            usleep(800);
        }

        if (src) CFRelease(src);
        atomic_fetch_sub(&gActiveReplacementsCount, 1);
    });
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self.eventTap) {
            CGEventTapEnable(self.eventTap, true);
        }
        [self resetBuffer];
        return event;
    }

    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kSyntheticEventMagic) {
        return event;
    }

    if (!self.isEnabled || ![self isTargetAppFrontmost]) {
        [self resetSentenceAndWordBuffer];
        return event;
    }

    if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown) {
        [self resetSentenceAndWordBuffer];
        return event;
    }

    if (type != kCGEventKeyDown) {
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    if ((flags & kCGEventFlagMaskCommand) || (flags & kCGEventFlagMaskControl)) {
        [self resetSentenceAndWordBuffer];
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    if (keyCode == kKeyCodeEscape || keyCode == kKeyCodeTab) {
        [self resetSentenceAndWordBuffer];
        return event;
    }

    // Setas de navegação movem o cursor para o meio de palavras já escritas -> ignora até o próximo espaço/Enter
    if (keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126) {
        [self resetSentenceAndWordBuffer];
        self.skipCurrentWord = YES;
        return event;
    }

    // Corrige também a última palavra de parágrafos/tópicos ao apertar Enter (desde que não seja comando / ou @)
    if (keyCode == kKeyCodeReturn || keyCode == kKeyCodeEnter) {
        if (!self.skipCurrentWord && self.wordBuffer.length >= 2) {
            NSString *currentWord = [self.wordBuffer copy];
            BOOL hadDot = self.wordHasTrailingDot;
            NSString *corrected = [self correctionForWord:currentWord];
            [self resetSentenceAndWordBuffer];

            if (corrected && ![corrected isEqualToString:currentWord]) {
                NSUInteger commonPrefix = 0;
                NSUInteger minLen = MIN(currentWord.length, corrected.length);
                while (commonPrefix < minLen &&
                       [currentWord characterAtIndex:commonPrefix] == [corrected characterAtIndex:commonPrefix]) {
                    commonPrefix++;
                }

                NSUInteger charsToDelete = (currentWord.length - commonPrefix) + (hadDot ? 1 : 0);
                NSString *suffixToInsert = [NSString stringWithFormat:@"%@%@",
                                            [corrected substringFromIndex:commonPrefix],
                                            (hadDot ? @"." : @"")];

                self.lastCorrectionDisplay = [NSString stringWithFormat:@"%@ → %@", currentWord, corrected];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateStatusUI];
                });

                [self sendBackspaces:charsToDelete thenString:suffixToInsert thenKeyCode:keyCode];
                return NULL;
            }
        }
        [self resetSentenceAndWordBuffer];
        if (atomic_load(&gActiveReplacementsCount) > 0) {
            [self sendBackspaces:0 thenString:nil thenKeyCode:keyCode];
            return NULL;
        }
        return event;
    }

    if (keyCode == kKeyCodeBackspace) {
        self.deadKeyState = 0;
        if (self.canUndoLastCorrection && self.lastOriginalWord && self.lastCorrectedWord) {
            NSString *orig = self.lastOriginalWord;
            NSString *corr = self.lastCorrectedWord;
            self.canUndoLastCorrection = NO;
            NSString *lowerOrig = [orig lowercaseStringWithLocale:[self currentLocale]];
            [self.ignoredOnceWords addObject:lowerOrig];
            [self.ignoredWordsSet addObject:lowerOrig];

            NSUInteger commonLen = 0;
            NSUInteger minLen = MIN(orig.length, corr.length);
            while (commonLen < minLen && [orig characterAtIndex:commonLen] == [corr characterAtIndex:commonLen]) {
                commonLen++;
            }
            NSUInteger backspacesNeeded = (corr.length - commonLen) + 1;
            NSString *restoreSuffix = [orig substringFromIndex:commonLen];

            [self sendBackspaces:backspacesNeeded thenString:restoreSuffix];
            [self.wordBuffer setString:orig];
            self.lastCorrectionDisplay = [NSString stringWithFormat:[self tr:@"undone"], orig];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self saveIgnoredWords];
            });
            return NULL;
        }

        if (self.wordHasTrailingDot) {
            self.wordHasTrailingDot = NO;
            if (atomic_load(&gActiveReplacementsCount) > 0) {
                [self sendBackspaces:1 thenString:nil];
                return NULL;
            }
            return event;
        }

        if (self.wordBuffer.length > 0) {
            [self.wordBuffer deleteCharactersInRange:NSMakeRange(self.wordBuffer.length - 1, 1)];
        } else {
            // Backspace com wordBuffer vazio significa que o cursor voltou para dentro da palavra anterior -> evita corromper sufixo!
            self.skipCurrentWord = YES;
        }
        if (atomic_load(&gActiveReplacementsCount) > 0) {
            [self sendBackspaces:1 thenString:nil];
            return NULL;
        }
        return event;
    }

    UniChar chars[8];
    UniCharCount actualLen = 0;

    // Usa UCKeyTranslate para compor dead-keys (' + c = ç, ~ + a = ã, ´ + e = é) exatamente igual ao layout ativo (ex.: Brazilian - Pro)
    BOOL isSelfTestEvent = (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) == getpid());
    if (!isSelfTestEvent) {
        TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
        if (inputSource) {
            CFDataRef layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
            if (layoutData) {
                const UCKeyboardLayout *kbdLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
                UInt32 mod = 0;
                if (flags & kCGEventFlagMaskShift)      mod |= (shiftKey >> 8);
                if (flags & kCGEventFlagMaskAlphaShift) mod |= (alphaLock >> 8);
                if (flags & kCGEventFlagMaskAlternate)  mod |= (optionKey >> 8);
                UInt32 deadState = self.deadKeyState;
                OSStatus status = UCKeyTranslate(kbdLayout,
                                                 keyCode,
                                                 kUCKeyActionDown,
                                                 mod,
                                                 LMGetKbdType(),
                                                 0,
                                                 &deadState,
                                                 8,
                                                 &actualLen,
                                                 chars);
                self.deadKeyState = deadState;
                if (status != noErr) {
                    actualLen = 0;
                }
            }
            CFRelease(inputSource);
        } else {
            CGEventKeyboardGetUnicodeString(event, 8, &actualLen, chars);
        }
    } else {
        CGEventKeyboardGetUnicodeString(event, 8, &actualLen, chars);
    }

    if (actualLen == 0) {
        // Dead-key em andamento (ex.: apertou ' antes de c para fazer ç, ou ~ antes de a para fazer ã): aguarda a próxima tecla!
        return event;
    }

    self.canUndoLastCorrection = NO;
    NSString *typedStr = [NSString stringWithCharacters:chars length:actualLen];
    unichar ch = chars[0];

    // Se houver uma substituição ainda em trânsito (< 5ms), enfileira a tecla física na sendQueue para manter a ordem exata
    BOOL shouldQueuePhysicalKey = (atomic_load(&gActiveReplacementsCount) > 0);

    if (ch == '/' || ch == '@' || ch == '#' || ch == '`') {
        self.skipCurrentWord = YES;
        if (shouldQueuePhysicalKey) {
            [self sendBackspaces:0 thenString:typedStr];
            return NULL;
        }
        return event;
    }

    if (ch == ':') {
        NSString *lowerBuf = [self.wordBuffer lowercaseString];
        BOOL isUrlScheme = ([lowerBuf isEqualToString:@"http"] ||
                            [lowerBuf isEqualToString:@"https"] ||
                            [lowerBuf isEqualToString:@"mailto"] ||
                            [lowerBuf isEqualToString:@"file"] ||
                            [lowerBuf isEqualToString:@"ftp"]);
        if (self.wordBuffer.length == 0 || isUrlScheme) {
            self.skipCurrentWord = YES;
            if (shouldQueuePhysicalKey) {
                [self sendBackspaces:0 thenString:typedStr];
                return NULL;
            }
            return event;
        }
        // Caso contrário (ex.: "Introducao:", "Conclusao:"), ':' é tratado como delimitador de pontuação abaixo!
    }

    if (ch == '.') {
        if (self.wordBuffer.length > 0 && !self.skipCurrentWord && !self.wordHasTrailingDot) {
            self.wordHasTrailingDot = YES;
        } else {
            self.skipCurrentWord = YES;
            self.wordHasTrailingDot = NO;
        }
        if (shouldQueuePhysicalKey) {
            [self sendBackspaces:0 thenString:typedStr];
            return NULL;
        }
        return event;
    }

    BOOL isDelimiter = (keyCode == kKeyCodeSpace ||
                        ch == ' ' || ch == ',' || ch == ';' || ch == '!' || ch == '?' ||
                        ch == ':' || ch == ')' || ch == ']' || ch == '"' || ch == 0x201D);

    if (isDelimiter) {
        if (!self.skipCurrentWord && self.wordBuffer.length >= 2) {
            NSString *currentWord = [self.wordBuffer copy];
            BOOL hadDot = self.wordHasTrailingDot;
            [self.sentenceBuffer appendFormat:@"%@%@%@", currentWord, (hadDot ? @"." : @""), typedStr];
            if (self.sentenceBuffer.length > 120) {
                [self.sentenceBuffer deleteCharactersInRange:NSMakeRange(0, self.sentenceBuffer.length - 120)];
            }
            NSString *corrected = [self correctionForWord:currentWord];
            [self resetBuffer];

            if (corrected && ![corrected isEqualToString:currentWord]) {
                NSUInteger commonPrefix = 0;
                NSUInteger minLen = MIN(currentWord.length, corrected.length);
                while (commonPrefix < minLen &&
                       [currentWord characterAtIndex:commonPrefix] == [corrected characterAtIndex:commonPrefix]) {
                    commonPrefix++;
                }

                NSUInteger charsToDelete = (currentWord.length - commonPrefix) + (hadDot ? 1 : 0);
                NSString *suffixToInsert = [NSString stringWithFormat:@"%@%@%@",
                                            [corrected substringFromIndex:commonPrefix],
                                            (hadDot ? @"." : @""),
                                            typedStr];

                self.lastOriginalWord = currentWord;
                self.lastCorrectedWord = corrected;
                self.canUndoLastCorrection = !hadDot;
                self.lastCorrectionDisplay = [NSString stringWithFormat:@"%@ → %@", currentWord, corrected];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateStatusUI];
                });

                [self sendBackspaces:charsToDelete thenString:suffixToInsert];
                return NULL;
            }
        }
        [self resetBuffer];
        if (shouldQueuePhysicalKey) {
            [self sendBackspaces:0 thenString:typedStr];
            return NULL;
        }
        return event;
    }

    if (self.wordHasTrailingDot) {
        // Letra/caractere logo após '.' sem espaço (ex.: google.com, arquivo.pdf) -> ignora domínio/arquivo
        self.wordHasTrailingDot = NO;
        self.skipCurrentWord = YES;
    }

    if (self.skipCurrentWord) {
        if (shouldQueuePhysicalKey) {
            [self sendBackspaces:0 thenString:typedStr];
            return NULL;
        }
        return event;
    }

    if ([[NSCharacterSet letterCharacterSet] characterIsMember:ch]) {
        [self.wordBuffer appendString:typedStr];
        if (self.wordBuffer.length > 40) {
            self.skipCurrentWord = YES;
        }
    } else if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:ch] || ch == '_' || ch == '-') {
        self.skipCurrentWord = YES;
    } else {
        [self resetBuffer];
    }

    if (shouldQueuePhysicalKey) {
        [self sendBackspaces:0 thenString:typedStr];
        return NULL;
    }
    return event;
}

@end

static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    @autoreleasepool {
        return [gController handleEvent:event type:type];
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        BOOL bg = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--background") == 0) bg = YES;
        }
        [app setActivationPolicy:(bg ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular)];
        NotionAutocorrectController *delegate = [[NotionAutocorrectController alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
