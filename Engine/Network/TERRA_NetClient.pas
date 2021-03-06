{***********************************************************************************************************************
 *
 * TERRA Game Engine
 * ==========================================
 *
 * Copyright (C) 2003, 2014 by S�rgio Flores (relfos@gmail.com)
 *
 ***********************************************************************************************************************
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 **********************************************************************************************************************
 * TERRA_NetClient
 * Implements a generic multiplayer game client interface
 ***********************************************************************************************************************
}
Unit TERRA_NetClient;

{$I terra.inc}

Interface
Uses TERRA_String, TERRA_Application, TERRA_OS, TERRA_Sockets, TERRA_Network;

Type
  NetClient = Class(NetObject)
    Protected
      _Status:NetStatus;             // Connection to server status
      _ServerAddress:SocketAddress;  // Address of the server
      _GUID:Word;                     // Random number used by the server to search for duplicate Clients
      _PingStart:Cardinal;    // Used to measure latency
      _JoinTime:Cardinal;

      _IsConnecting:Boolean;
      _UserName:TERRAString;
      _Password:TERRAString;
      _TCPSocket:Socket;

      Procedure ClearConnection(ErrorCode:Integer);

      Procedure UpdateGUID();

    Public
      //Creates a new client instance
      Constructor Create();

      //Destroys the client instance
      Procedure Release; Override; 

      //Connects to a server
      Procedure Connect(Port,Version:Word; Server,UserName,Password:TERRAString);

      //Disconnects from server
      Procedure Disconnect(ErrorCode:Integer=0);

      //Handles messages
      Procedure Update; Override;

      Function CreateJoinMessage(Username, Password, DeviceID:TERRAString; GUID:Word):NetMessage; //Creates a server message

      //Send a message to the server
      Procedure SendMessage(Msg:NetMessage);

      Procedure SendEmptyMessage(Opcode:Byte); 

      Procedure ConnectionStart; Virtual; //Event: When a connection start
      Procedure ConnectionEnd(ErrorCode:Integer; ErrorLog:TERRAString); Virtual;   //Event: When a connection ends

      Function IsConnected():Boolean;

      Function ValidateMessage(Msg:NetMessage):Boolean; Override;

      //Message handlers
      Procedure OnShutdownMessage(Msg:NetMessage; Sock:Socket);

      Property IsConnecting:Boolean Read _IsConnecting;

      Property Status:NetStatus Read _Status;
  End;

Implementation
Uses TERRA_Log;

{ NetClient }
Function NetClient.CreateJoinMessage(Username, Password, DeviceID:TERRAString; GUID:Word):NetMessage; //Creates a server message
Begin
  Result := NetMessage.Create(nmClientJoin);
  Result.Owner := ID_UNKNOWN;
  Result.Write(@GUID, 2);
  Result.Write(@_Version, 2);
  Result.WriteString(Username);
  Result.WriteString(Password);
  Result.WriteString(DeviceID);
End;

Procedure NetClient.OnShutdownMessage(Msg:NetMessage; Sock:Socket);
Var
  Code:Word;
Begin
  Msg.Read(@Code, 2);
  Disconnect(Code);
End;

 // Creates a new client instance
Constructor NetClient.Create();
Begin
  Inherited Create();

  NetworkManager.Instance.AddObject(Self);

  _Status := nsDisconnected;

  _OpcodeList[nmServerShutdown] := OnShutdownMessage;

  UpdateGUID();
End;

// Disconnects from server and destroys the client instance
Procedure NetClient.Release;
Begin
  NetworkManager.Instance.RemoveObject(Self);

  While (ReceivePacket(_TCPSocket)) Do;

  Disconnect();

  If Assigned(_TCPSocket) Then
  Begin
    _TCPSocket.Release;
    _TCPSocket := Nil;
  End;

  Inherited Release();
End;


Procedure NetClient.UpdateGUID();
Begin
  _GUID := (GetTime() Mod 65214);
End;

Function NetClient.ValidateMessage(Msg:NetMessage):Boolean;
Var
  Code:Word;
  ErrorLog:TERRAString;
Begin
  //Is this an ACK?
  Case Msg.Opcode Of
    nmServerAck:
      Begin
        //Set our ID
        Msg.Read(@Code, 2);
        _LocalID := Code;
        _Status := nsConnected;
        _IsConnecting := False;
        ConnectionStart();
        Result := False;
        Exit;
      End;

    nmServerError:
      Begin
        Msg.Read(@Code, 2);
        Msg.ReadString(ErrorLog);
        Log(logError,'Network','ErrorMessage: '+GetNetErrorDesc(Code));

        Result := False;
        If (Code = errAlreadyConnected) And (Self.IsConnected) Then
        Begin
          Exit;
          // do nothing
        End Else
        Begin
          _IsConnecting := False;
          Self.ConnectionEnd(Code, ErrorLog);
          UpdateGUID();
          Exit;
        End;
      End;
    Else
      Result := True;
  End;
End;

Procedure NetClient.Connect(Port,Version:Word; Server, UserName, Password:TERRAString);
Var
  JoinMsg:NetMessage;
Begin
  If (_IsConnecting) Or (_TCPSocket<>Nil) Then
    Exit;

  _Port := Port;
  _Version := Version;
  _UserName := UserName;
  _Password := Password;

  _IsConnecting := True;

  Log(logDebug,'Network', Self.ClassName+'.Connect: '+Server);

  //Create a socket for sending/receiving messages
  _TCPSocket := Socket.Create(Server, _Port);
  If (_TCPSocket.Closed) Then
  Begin
    Self.ClearConnection(errConnectionFailed);
  End Else
  Begin
    _TCPSocket.SetBlocking(False);
    _TCPSocket.SetDelay(False);
    _JoinTime := GetTime();

    Log(logDebug, 'Network', 'Sending join message');
    JoinMsg := CreateJoinMessage(_UserName, _Password, Application.Instance.GetDeviceID(), _GUID);
    SendMessage(JoinMsg);  //Send the packet
    JoinMsg.Release();
  End;
End;

// Handles messages
Procedure NetClient.Update;
Var
  Delta:Integer;
Begin
  UpdateIO();

  If (Assigned(_TCPSocket)) Then
  Begin
    // Process messages
    While ReceivePacket(_TCPSocket) Do;
  End;

  If (_IsConnecting) Then
  Begin
    Delta := GetTime() - _JoinTime;
    If (Delta>20*1000) Then
    Begin
      _IsConnecting := False;
      Self.ClearConnection(errConnectionTimeOut);
    End;
  End;

  If (Self._TCPSocket<>Nil) And (Self._TCPSocket.Closed) Then
  Begin
    {$IFNDEF STAYALIVE}
    Log(logWarning,'Network', Self.ClassName+'.Update: Connection lost');
    Disconnect(errConnectionLost); //Conection lost
    {$ENDIF}
  End;
End;

Procedure NetClient.ClearConnection(ErrorCode:Integer);
Begin
  _Status := nsDisconnected;
  ConnectionEnd(ErrorCode,'');

  If Assigned(_TCPSocket) Then
  Begin
    _TCPSocket.Release;
    _TCPSocket := Nil;
  End;
End;

// Send a message to the server
Procedure NetClient.SendMessage(Msg:NetMessage);
Begin
  If (Msg = Nil) Then
    Exit;

  If (_Status <> nsConnected) And (Msg.Opcode<>nmClientJoin) Then
    Exit;

  //_NextPong := GetTime() + PONG_TIME;
  If (Msg.Opcode <> nmClientJoin) Then
    Msg.Owner := _LocalID;

  If Not SendPacket(_ServerAddress, _TCPSocket, Msg) Then
  Begin
    ClearConnection(errConnectionLost);
  End;
End;

// Send a message to the server
Procedure NetClient.Disconnect(ErrorCode:Integer=0);
Begin
  If (_Status <> nsConnected) Then
    Exit;

  Self.SendEmptyMessage(nmClientDrop);
  ClearConnection(ErrorCode);
End;

Procedure NetClient.ConnectionStart; //Event: When a connection start
Begin
End;

Procedure NetClient.ConnectionEnd;   //Event: When a connection end
Begin
End;

Function NetClient.IsConnected():Boolean;
Begin
  Result := (Self._Status = nsConnected);
End;

Procedure NetClient.SendEmptyMessage(Opcode: Byte);
Var
  Msg:NetMessage;
Begin
  Msg := NetMessage.Create(Opcode);
  Self.SendMessage(Msg);
  Msg.Release();
End;

End.