/// Сервис для обмена событиями между клиентом и сервером.
/// Перед использованием необходимо получить токен авторизованного
/// пользователя и зарегистрироваться на socket сервере LKO.
library socket_service;

import 'dart:async';
import 'dart:convert';
import 'dart:html';

/// Для того что бы определить где находится socket сервер LKO,
/// на каком порту и какой протокол используется нужно эту информацию
/// получить. Эта информация содержится в configuration.yaml в
/// директории web. Запросив этот файл у сервера, его нужно разобрать
/// структуру типа Map. Для этого используется пакет yaml.
import 'package:yaml/yaml.dart';

// Необходим injector и аннотация @injectable
import 'package:angular/angular.dart';

/// ReactiveX позволит более удобным способом подписываться и фильтровать события
/// приходящие с сервера по протоколу websocket.
import 'package:rxdart/rxdart.dart';

/// Injector должен уметь обнаруживать сервисы.
/// Для этого, сервисы нужно помечать аннотацией @Injectable.
/// Тогда уже можно будет указывать в зависимостях этот сервис.
@Injectable()
class SocketService {
  WebSocket
      socketConnection; // Подключение куда отправляются события и откуда приходят
  Map configuraion; // Настройки socket сервера LKO

  // События которые отправляются на socket сервер LKO
  List eventPool = new List();

  /// Позволяет определить установлено ли соединение
  /// с сервером в случаи разрыва или нет.
  bool reconnectionInProgress = false;

  StreamController dataControl = new StreamController();

  /// Компоненты которые нуждаются в событиях сокета прослушивают этот stream
  Stream<Map> data;

  /// Функция получает данные о конфигурации socket сервера LKO.
  Future<Null> _setUpConfiguration() async {
    String protocol = window.location.protocol;
    String host =
        window.location.host.replaceAll(":${window.location.port}", '');
    int port = int.parse(window.location.port);

    try {
      String configFile = await HttpRequest
          .getString('$protocol//$host:$port/configuration.yaml');

      configuraion = loadYaml(configFile);
    } catch (error) {
      print(error);
    }
  }

  /// Получая событие от сервера нужно JSON строку разобрать в
  /// Map структуру.
  /// От Observable из stream приходит MessageEvent объект.
  /// Метод может разобрать как строку так и событие которое
  /// содержит в себе строку. Это делает метод более универсальным,
  /// и позволяет проще реализовать Mock сервиса, не реализовывая
  /// Observable цепочку.
  Map _decodeSocketData(event) {
    Map data;
    if (event is String) data = JSON.decode(event);
    if (event is MessageEvent) data = JSON.decode(event.data);

    return data;
  }

  /// После того как данные о событии с сервера будут представлены
  /// в виде структуры Map, их можно отправлять в поток событий: data,
  /// на который подписывются остальные сервисы и компоненты.
  void _finalizeData(Map socketData) => dataControl.add(socketData);

  /// Конструктор сервиса
  SocketService() {
    data = dataControl.stream.asBroadcastStream() as Stream<Map>;

    if (configuraion == null) {
      /// Получения данных о socket сервере, после чего
      /// происходит подключение к серверу.
      _setUpConfiguration().then((_) {
        connect();
      });
    } else {
      connect();
    }
  }

  /// Подключение к серверу
  /// TODO: Добавить в метод connect поля адреса и порта сервера
  void connect({String location, int port}) {
    try {
      String protocol = configuraion['production']['socket']['protocol'];
      String ip;

      if (configuraion['production']['socket']['ip'] != null) {
        ip = configuraion['production']['socket']['ip'];
      } else {
        ip = window.location.hostname;
      }

      String port = configuraion['production']['socket']['port'].toString();

      String iri = "$protocol://$ip:$port/";

      /// Подключение к сокету WebServerLKO
      socketConnection = new WebSocket(iri);
      print("Socket connection in progress");

      socketConnection.onOpen.listen((Event event) {
        /// Если подключение осуществлялось в случаи разрыва соединения
        /// нужно отправить уведомление об успешном переподключении.
        if (reconnectionInProgress == true) {
          print("Client reconnected to server");

          /// После подключения к серверу, если есть не отправленные события
          /// их нужно отправить.
          if (eventPool.isNotEmpty) {
            for (String eventData in eventPool) {
              socketConnection.send(eventData);
            }
          }

          // Отправление уведомления об успешном переподключении
          dataControl.add({'Message': "Client reconnected to server"});
        }

        reconnectionInProgress = false;
        print("Socket connected to server");
      });

      /// После подключения к socket серверу LKO
      /// нужно подписаться на события приходящие с сервера.
      subscribeToEvents(socketConnection.onMessage);

      /// При закрытии соединения, нужно оповестить об этом
      /// другие компоненты. И начать подключение заново.
      socketConnection.onClose.listen((_) {
        dataControl.add({'Message': "Connection closed"});
        print("Socket connection is closed");

        /// В случае разрыва соединения необходимо осуществить попытку
        /// установления связи с сервером повторно.
        reconnect(durationInSeconds: 3);
      });
    } catch (error) {
      print(error);
    }
  }

  /// Через каждые 3 секунды (по умолчанию) клиент предпринимает
  /// попытки востановить соединение.
  /// Подробнее: при подключении, если сервер будет не доступен, socketConnection
  /// обработает событие onClose где вновь будет вызван метод reconnect.
  void reconnect({int durationInSeconds: 3}) {
    new Timer(new Duration(seconds: durationInSeconds), () => connect());
    reconnectionInProgress = true;
  }

  /// Метод который подписывается на stream событий от сервера
  Future<Null> subscribeToEvents(Stream eventChannel) async {
    /// Используя RxDart осуществляется подписка на stream
    Observable socketChannel = new Observable(eventChannel);

    /// Когда в сокет приходят данные их нужно раскодировать и опубликовать
    /// с помощью EventEmitter'a фрейморка Angular.
    socketChannel.map(_decodeSocketData).listen(_finalizeData);
  }

  /// Отправляя событие с клиента на сервер нужно убедиться в том что клиент
  /// подключен к socket серверу.
  /// Функция которая ожидает подключения к socket серверу LKO перед тем как
  /// отправить событие.
  void waitForSocketConnection(
      WebSocket socket, String eventData, int iterator) {
    if (iterator != 0) {
      iterator--;
      // Используется таймер
      new Timer(new Duration(seconds: 1), () {
        if (socket.readyState == 1) {
          /// Когда подключение к серверу будет установлено,
          /// сообщение будет отправлено.
          socket.send(eventData);

          /// В случае успешной отправки события на сервер
          /// его можно удалять из списка не отправленных событий.
          eventPool.remove(eventData);
        } else {
          print("Wait for connection... Attempt: $iterator");

          /// Если подключение к socket серверу еще в процессе
          /// по окончании времени используется рекурсивный вызов функции
          /// до тех пор пока подключение не будет установлено.
          waitForSocketConnection(socket, eventData, iterator);
        }
      });
    } else {
      print("Socket must be reconnected");
    }
  }

  /// Метод для отправки событий на сервер
  Future<Null> write(String message, [Map details]) async {
    Map data = new Map<String, dynamic>();

    data['Message'] = message;
    data['Details'] = details;

    /// Событие необходимо добавить в общий пул событий.
    /// Это позволит в случае разъединения отправить событие на сервер
    /// повторно при подключении.
    String encodedData = JSON.encode(data);
    eventPool.add(encodedData);

    /// Перед отправкой сообщения нужно убедиться в том, что
    /// связь с socket сервером LKO установлена.
    /// Последним параметром указывается количество секунд ожидания
    /// соединения.
    waitForSocketConnection(socketConnection, encodedData, 5);
  }

  /// Метод закрытия соеднинения с socket сервером
  Future<Null> connectionClose() async {
    try {
      socketConnection.close();
    } catch (error) {
      print(error);
    }
  }
}
