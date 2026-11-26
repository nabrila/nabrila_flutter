import 'dart:ui';

/// Strings of the capture flow. English by default; `es` and `pt` follow the
/// device locale. A plain map on purpose: no codegen.
class NabrilaStrings {
  NabrilaStrings._(this._values);

  final Map<String, String> _values;

  /// Picks the language from the device locale and falls back to English.
  factory NabrilaStrings.forLocale(Locale locale) =>
      NabrilaStrings._(_catalog[locale.languageCode] ?? _en);

  String _t(String key) => _values[key] ?? _en[key] ?? key;

  String get reportBug => _t('reportBug');
  String get notePlaceholder => _t('notePlaceholder');
  String get nativeWarning => _t('nativeWarning');
  String get pen => _t('pen');
  String get hide => _t('hide');
  String get undo => _t('undo');
  String get cancel => _t('cancel');
  String get send => _t('send');
  String get sending => _t('sending');
  String get linkReady => _t('linkReady');
  String get linkWarning => _t('linkWarning');
  String get copy => _t('copy');
  String get copied => _t('copied');
  String get share => _t('share');
  String get close => _t('close');
  String get retry => _t('retry');
  String get keyCustodyFailed => _t('keyCustodyFailed');
  String get captureFailed => _t('captureFailed');
  String get errInvalidKey => _t('errInvalidKey');
  String get errSuspended => _t('errSuspended');
  String get errTooLarge => _t('errTooLarge');
  String get errQuota => _t('errQuota');
  String get errRateLimited => _t('errRateLimited');
  String get errBadEnvelope => _t('errBadEnvelope');
  String get errNetwork => _t('errNetwork');
  String get savedForLater => _t('savedForLater');
  String get deliveredLater => _t('deliveredLater');
  String get errServer => _t('errServer');
  String get floatingButton => _t('floatingButton');
  String get loopFixed => _t('loopFixed');
  String get loopNeedsInfo => _t('loopNeedsInfo');
  String get loopWontFix => _t('loopWontFix');
  String get loopNoteFrom => _t('loopNoteFrom');
  String get kindBug => _t('kindBug');
  String get kindVisual => _t('kindVisual');
  String get kindData => _t('kindData');
  String get kindSuggestion => _t('kindSuggestion');
  String get point => _t('point');
  String get pointMarked => _t('pointMarked');
  String get clearPoint => _t('clearPoint');
  String get nativeView => _t('nativeView');
  String get included => _t('included');
  String get includedScreenshot => _t('includedScreenshot');
  String get includedReplay => _t('includedReplay');
  String get includedEvents => _t('includedEvents');
  String get includedBodies => _t('includedBodies');
  String get includedNoBodies => _t('includedNoBodies');
  String get includedContext => _t('includedContext');
  String get includedDevice => _t('includedDevice');
  String get includedEncrypted => _t('includedEncrypted');
}

const Map<String, Map<String, String>> _catalog = {
  'en': _en,
  'es': _es,
  'pt': _pt,
};

const Map<String, String> _en = {
  'reportBug': 'Report',
  'notePlaceholder': 'What went wrong?',
  'nativeWarning':
      'Maps, web views and video players are native views: the screenshot marks them, and they can look blank or old. The system keyboard never shows.',
  'pen': 'Draw',
  'hide': 'Hide',
  'undo': 'Undo',
  'cancel': 'Cancel',
  'send': 'Send',
  'sending': 'Sending…',
  'linkReady': 'Report ready',
  'linkWarning':
      'Anyone with this full link can open the report. Share it only where you trust.',
  'copy': 'Copy link',
  'copied': 'Link copied',
  'share': 'Share',
  'close': 'Close',
  'retry': 'Try again',
  'keyCustodyFailed':
      'The link works, but your team inbox could not store the key.',
  'captureFailed': 'The screen could not be captured.',
  'errInvalidKey': 'This build has an invalid Nabrila key.',
  'errSuspended': 'This Nabrila account is suspended.',
  'errTooLarge': 'The report is too large to send.',
  'errQuota':
      'This app reached its monthly report limit. Ask your team to check their Nabrila plan.',
  'errRateLimited': 'Too many reports in a short time. Try again in a minute.',
  'errBadEnvelope': 'The server rejected the report.',
  'errNetwork': 'No connection. Check your network and try again.',
  'errServer': 'Something went wrong on the server. Try again later.',
  'savedForLater':
      'Your report is saved on this phone and will be sent on its own as soon as it can. You will see the link here when it goes out.',
  'deliveredLater': 'A saved report was sent.',
  'floatingButton': 'Report a bug',
  'loopFixed': 'Your report was fixed. Try it again.',
  'loopNeedsInfo': 'The team needs more details about your report.',
  'loopWontFix': 'The team reviewed your report and will leave it as it is.',
  'loopNoteFrom': 'From the team: {note}',
  'kindBug': 'Something fails',
  'kindVisual': 'Looks wrong',
  'kindData': 'Wrong data',
  'kindSuggestion': 'Idea',
  'point': 'Point',
  'pointMarked': 'Spot marked',
  'clearPoint': 'Remove the mark',
  'nativeView': 'Native view · may differ',
  'included': 'What gets sent',
  'includedScreenshot':
      'This screenshot, with your drawings. The zones the app marks as private are covered.',
  'includedReplay':
      'The last {n} s on screen, with text fields and private zones covered.',
  'includedEvents':
      '{taps} taps, {screens} screen changes, {requests} network requests and {logs} log lines.',
  'includedBodies':
      'Requests keep their headers and bodies, with passwords, tokens and cookies replaced by [REDACTED].',
  'includedNoBodies':
      'Requests go without headers or bodies: method, address without secrets, status and time.',
  'includedContext': 'Data from the app: {keys}.',
  'includedDevice': 'App version, system, screen size and language.',
  'includedEncrypted':
      'Everything is encrypted on this phone before it leaves.',
};

const Map<String, String> _es = {
  'reportBug': 'Reportar',
  'notePlaceholder': '¿Qué salió mal?',
  'nativeWarning':
      'Los mapas, las vistas web y los reproductores de video son vistas nativas: la captura las marca y pueden verse en blanco o viejas. El teclado del sistema nunca sale.',
  'pen': 'Dibujar',
  'hide': 'Tapar',
  'undo': 'Deshacer',
  'cancel': 'Cancelar',
  'send': 'Enviar',
  'sending': 'Enviando…',
  'linkReady': 'Reporte listo',
  'linkWarning':
      'Quien tenga este enlace completo puede abrir el reporte. Compártelo solo donde confíes.',
  'copy': 'Copiar enlace',
  'copied': 'Enlace copiado',
  'share': 'Compartir',
  'close': 'Cerrar',
  'retry': 'Reintentar',
  'keyCustodyFailed':
      'El enlace funciona, pero la bandeja de tu equipo no pudo guardar la llave.',
  'captureFailed': 'No se pudo capturar la pantalla.',
  'errInvalidKey': 'Esta compilación tiene una clave de Nabrila inválida.',
  'errSuspended': 'Esta cuenta de Nabrila está suspendida.',
  'errTooLarge': 'El reporte es demasiado grande para enviarlo.',
  'errQuota':
      'Esta app alcanzó su límite mensual de reportes. Pide a tu equipo que revise su plan de Nabrila.',
  'errRateLimited':
      'Demasiados reportes en poco tiempo. Inténtalo de nuevo en un minuto.',
  'errBadEnvelope': 'El servidor rechazó el reporte.',
  'errNetwork': 'Sin conexión. Revisa tu red e inténtalo de nuevo.',
  'errServer': 'Algo falló en el servidor. Inténtalo más tarde.',
  'savedForLater':
      'Tu reporte quedó guardado en este teléfono y se enviará solo apenas se pueda. Verás el enlace aquí cuando salga.',
  'deliveredLater': 'Se envió un reporte que estaba guardado.',
  'floatingButton': 'Reportar un error',
  'loopFixed': 'Tu reporte quedó corregido. Pruébalo de nuevo.',
  'loopNeedsInfo': 'El equipo necesita más detalles sobre tu reporte.',
  'loopWontFix': 'El equipo revisó tu reporte y lo dejará como está.',
  'loopNoteFrom': 'Del equipo: {note}',
  'kindBug': 'Algo falla',
  'kindVisual': 'Se ve mal',
  'kindData': 'Dato incorrecto',
  'kindSuggestion': 'Idea',
  'point': 'Señalar',
  'pointMarked': 'Punto marcado',
  'clearPoint': 'Quitar la marca',
  'nativeView': 'Vista nativa · puede diferir',
  'included': 'Qué se envía',
  'includedScreenshot':
      'Esta captura, con lo que dibujaste. Las zonas que la app marca como privadas salen tapadas.',
  'includedReplay':
      'Los últimos {n} s en pantalla, con los campos de texto y las zonas privadas tapados.',
  'includedEvents':
      '{taps} toques, {screens} cambios de pantalla, {requests} solicitudes de red y {logs} líneas de registro.',
  'includedBodies':
      'Las solicitudes llevan cabeceras y cuerpos, con contraseñas, tokens y cookies cambiados por [REDACTED].',
  'includedNoBodies':
      'Las solicitudes van sin cabeceras ni cuerpos: método, dirección sin secretos, estado y tiempo.',
  'includedContext': 'Datos de la app: {keys}.',
  'includedDevice': 'Versión de la app, sistema, tamaño de pantalla e idioma.',
  'includedEncrypted': 'Todo se cifra en este teléfono antes de salir.',
};

const Map<String, String> _pt = {
  'reportBug': 'Reportar',
  'notePlaceholder': 'O que deu errado?',
  'nativeWarning':
      'Mapas, web views e players de vídeo são views nativas: a captura as marca e elas podem aparecer em branco ou antigas. O teclado do sistema nunca aparece.',
  'pen': 'Desenhar',
  'hide': 'Cobrir',
  'undo': 'Desfazer',
  'cancel': 'Cancelar',
  'send': 'Enviar',
  'sending': 'Enviando…',
  'linkReady': 'Relatório pronto',
  'linkWarning':
      'Quem tiver este link completo pode abrir o relatório. Compartilhe só onde você confia.',
  'copy': 'Copiar link',
  'copied': 'Link copiado',
  'share': 'Compartilhar',
  'close': 'Fechar',
  'retry': 'Tentar de novo',
  'keyCustodyFailed':
      'O link funciona, mas a caixa de entrada da equipe não conseguiu guardar a chave.',
  'captureFailed': 'Não foi possível capturar a tela.',
  'errInvalidKey': 'Este build tem uma chave do Nabrila inválida.',
  'errSuspended': 'Esta conta do Nabrila está suspensa.',
  'errTooLarge': 'O relatório é grande demais para ser enviado.',
  'errQuota':
      'Este app atingiu o limite mensal de relatórios. Peça à equipe para revisar o plano do Nabrila.',
  'errRateLimited':
      'Relatórios demais em pouco tempo. Tente de novo em um minuto.',
  'errBadEnvelope': 'O servidor rejeitou o relatório.',
  'errNetwork': 'Sem conexão. Verifique sua rede e tente de novo.',
  'errServer': 'Algo deu errado no servidor. Tente mais tarde.',
  'savedForLater':
      'Seu relatório ficou salvo neste celular e será enviado sozinho assim que possível. Você verá o link aqui quando ele sair.',
  'deliveredLater': 'Um relatório salvo foi enviado.',
  'floatingButton': 'Reportar um bug',
  'loopFixed': 'Seu relatório foi corrigido. Teste de novo.',
  'loopNeedsInfo': 'A equipe precisa de mais detalhes sobre seu relatório.',
  'loopWontFix': 'A equipe revisou seu relatório e vai deixar como está.',
  'loopNoteFrom': 'Da equipe: {note}',
  'kindBug': 'Algo falha',
  'kindVisual': 'Aparece errado',
  'kindData': 'Dado errado',
  'kindSuggestion': 'Ideia',
  'point': 'Apontar',
  'pointMarked': 'Ponto marcado',
  'clearPoint': 'Tirar a marca',
  'nativeView': 'View nativa · pode diferir',
  'included': 'O que é enviado',
  'includedScreenshot':
      'Esta captura, com seus desenhos. As áreas que o app marca como privadas saem cobertas.',
  'includedReplay':
      'Os últimos {n} s na tela, com campos de texto e áreas privadas cobertos.',
  'includedEvents':
      '{taps} toques, {screens} trocas de tela, {requests} requisições de rede e {logs} linhas de log.',
  'includedBodies':
      'As requisições levam cabeçalhos e corpos, com senhas, tokens e cookies trocados por [REDACTED].',
  'includedNoBodies':
      'As requisições vão sem cabeçalhos nem corpos: método, endereço sem segredos, status e tempo.',
  'includedContext': 'Dados do app: {keys}.',
  'includedDevice': 'Versão do app, sistema, tamanho da tela e idioma.',
  'includedEncrypted': 'Tudo é criptografado neste celular antes de sair.',
};
