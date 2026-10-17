import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import UserNotifications

private enum BLE {
    static let service = CBUUID(string:"d62a0001-7d50-48ab-93d8-6080f2ccaa01")
    static let dog01 = CBUUID(string:"d62a0002-7d50-48ab-93d8-6080f2ccaa01")
    static let dog02 = CBUUID(string:"d62a0003-7d50-48ab-93d8-6080f2ccaa01")
    static let all = CBUUID(string:"d62a0004-7d50-48ab-93d8-6080f2ccaa01")
    static let control = CBUUID(string:"d62a0005-7d50-48ab-93d8-6080f2ccaa01")
}
struct Hop: Codable { let from:String; let to:String; let rssi:Double?; let snr:Double? }
struct DogRecord: Codable, Identifiable {
    let id:String
    let seq:Int?; let session:String?; let lat:Double?; let lon:Double?; let speed:Double?
    let sat:Int?; let satUso:Int?; let satIds:String?; let batV:Double?; let batPct:Int?
    let rssi:Double?; let snr:Double?; let receivedAt:Int?; let status:String?; let delivery:String?
    let ageMs:Int?; let route:[String]?; let links:[Hop]?
    let secondsSinceRx:Double?; let positionAgeS:Double?; let secondsSinceDirect:Double?
    let sendIntervalS:Int?; let requestedIntervalS:Int?; let configStatus:String?
    let contactTimeoutS:Double?; let contactLostAt:Int?; let lastDirectAt:Int?
    enum CodingKeys:String,CodingKey {
        case id,seq,session,lat,lon,speed,sat,rssi,snr,status,delivery,route,links
        case satUso="sat_uso",satIds="sat_ids",batV="bat_v",batPct="bat_pct",receivedAt="received_at"
        case ageMs="age_ms",secondsSinceRx="seconds_since_rx",positionAgeS="position_age_s"
        case secondsSinceDirect="seconds_since_direct",sendIntervalS="send_interval_s"
        case requestedIntervalS="requested_interval_s",configStatus="config_status"
        case contactTimeoutS="contact_timeout_s",contactLostAt="contact_lost_at",lastDirectAt="last_direct_at"
    }
    var coordinate:CLLocationCoordinate2D? {
        guard let lat,let lon,lat.isFinite,lon.isFinite,(-90...90).contains(lat),(-180...180).contains(lon) else{return nil}
        return CLLocationCoordinate2D(latitude:lat,longitude:lon)
    }
    var isRecent:Bool {
        if let status,status=="sem_contacto" || status=="posicao_antiga" {return false}
        return (positionAgeS ?? ageMs.map{Double($0)/1000} ?? 1e9)<(contactTimeoutS ?? 30)
    }
}
struct BaseChoice:Identifiable {let id:UUID;let name:String;let rssi:Int}
struct DogsEnvelope:Decodable {let dogs:[DogRecord]}
struct NetworkStats:Decodable {
    let knownCount:Int?;let relayLimit:Int?;let maxRelays:Int?
    let baseType:String?;let baseLat:Double?;let baseLon:Double?;let baseSat:Int?
    enum CodingKeys:String,CodingKey {case knownCount="known_count",relayLimit="relay_limit",maxRelays="max_relays",baseType="base_type",baseLat="base_lat",baseLon="base_lon",baseSat="base_sat"}
}
struct HistoryItem:Codable,Identifiable {
    var id=UUID();let dog:String;let at:Date;let type:String;let detail:String
    let lat:Double?;let lon:Double?;let battery:Int?;let seq:Int?;let session:String?
}

@MainActor final class CollarBluetooth:NSObject,ObservableObject,@preconcurrency CBCentralManagerDelegate,@preconcurrency CBPeripheralDelegate,UNUserNotificationCenterDelegate {
    @Published var bases:[BaseChoice]=[]
    @Published var baseName="Nenhuma base selecionada"
    private var discovered:[UUID:CBPeripheral]=[:]
    private var clockSent=false
    private var syncingClock=false
    private var disconnectRequested=false
    @Published var status="A iniciar Bluetooth…"
    @Published var dogs:[String:DogRecord]=[:]
    @Published var connected=false
    @Published var lastRead:Date?
    @Published var baseLostAt:Date?
    @Published var snapshots:[String:Date]=[:]
    @Published var network:NetworkStats?
    @Published var canConfigure=false
    @Published var commandFeedback=""
    @Published var history:[HistoryItem]=[]
    private var manager:CBCentralManager!
    private var raspberry:CBPeripheral?
    private var positions:[CBCharacteristic]=[]
    private var all:CBCharacteristic?
    private var control:CBCharacteristic?
    private var timer:Timer?
    private var busy=false
    private var startedRead=Date.distantPast
    private var assembled=Data()
    private var offset=0
    private var pageTotal:Int?
    private var pendingInterval:(String,Int)?
    private var lastSample:[String:String]=[:]
    private var contact:[String:Bool]=[:]
    private var lowBattery:[String:Bool]=[:]
    private var notifications=false
    private let historyURL=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("coleiras-historico-v6.json")
    override init(){
        super.init()
        if let data=try? Data(contentsOf:historyURL),let items=try? JSONDecoder().decode([HistoryItem].self,from:data){history=items}
        UNUserNotificationCenter.current().delegate=self
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.notifications=settings.authorizationStatus == .authorized }
        }
        manager=CBCentralManager(delegate:self,queue:.main)
    }
    var ids:[String]{dogs.keys.sorted{a,b in
        let x=Int(a.dropFirst(3)) ?? 0,y=Int(b.dropFirst(3)) ?? 0
        return x==y ? a<b : x<y
    }}
    func baseAvailable(_ now:Date)->Bool {connected && lastRead.map{now.timeIntervalSince($0)<15}==true}
    func elapsed(_ dog:DogRecord,_ now:Date)->Double {
        if let seconds=dog.secondsSinceRx,let date=snapshots[dog.id]{return max(0,seconds+now.timeIntervalSince(date))}
        return dog.receivedAt.map{max(0,now.timeIntervalSince1970-Double($0))} ?? 1e9
    }
    func lost(_ dog:DogRecord,_ now:Date)->Bool {elapsed(dog,now)>=(dog.contactTimeoutS ?? 30)}
    func scanBases(){
        guard manager.state == .poweredOn,raspberry==nil else{return}
        bases=[];discovered=[:];status="Escolhe o recetor Bluetooth"
        manager.scanForPeripherals(withServices:[BLE.service])
    }
    func chooseBase(_ id:UUID){
        guard raspberry==nil,let peripheral=discovered[id] else{return}
        manager.stopScan();raspberry=peripheral;peripheral.delegate=self
        disconnectRequested=false
        baseName=bases.first(where:{$0.id==id})?.name ?? "Recetor"
        dogs=[:];snapshots=[:];network=nil;lastRead=nil
        contact=[:];lowBattery=[:];lastSample=[:];clockSent=false;syncingClock=false
        status="A ligar a \(baseName)…";manager.connect(peripheral)
    }
    func disconnectBase(){
        guard let raspberry else{scanBases();return}
        timer?.invalidate();timer=nil;disconnectRequested=true;status="A desligar…"
        if connected,let control,control.properties.contains(.write){
            raspberry.writeValue(Data("ROLE,0".utf8),for:control,type:.withResponse)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds:2_000_000_000)
                guard let self,self.disconnectRequested,self.raspberry?.identifier==raspberry.identifier else{return}
                self.manager.cancelPeripheralConnection(raspberry)
            }
        }else{manager.cancelPeripheralConnection(raspberry)}
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager){
        if central.state == .poweredOn {scanBases()}
        else {connected=false;status="Bluetooth indisponível ou sem permissão"}
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber){
        discovered[peripheral.identifier]=peripheral
        let name=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Recetor Coleiras"
        let label=name=="Base-RPi" ? "Coleiras — Raspberry" : name
        let choice=BaseChoice(id:peripheral.identifier,name:label,rssi:RSSI.intValue)
        if let i=bases.firstIndex(where:{$0.id==choice.id}){bases[i]=choice}else{bases.append(choice)}
    }
    func centralManager(_ central:CBCentralManager,didConnect peripheral:CBPeripheral){
        guard raspberry?.identifier==peripheral.identifier else{return}
        connected=true;baseLostAt=nil;status="Ligado a \(baseName)";peripheral.discoverServices([BLE.service])
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect peripheral:CBPeripheral,error:Error?){resetConnection(peripheral)}
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral peripheral:CBPeripheral,error:Error?){resetConnection(peripheral)}
    private func resetConnection(_ peripheral:CBPeripheral){
        guard raspberry?.identifier==peripheral.identifier else{return}
        timer?.invalidate();timer=nil;connected=false;baseLostAt=Date();raspberry=nil
        positions=[];all=nil;control=nil;busy=false;canConfigure=false;pendingInterval=nil;clockSent=false;syncingClock=false
        disconnectRequested=false;status="Ligação terminada. Escolhe o recetor.";scanBases()
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverServices error:Error?){
        guard error==nil,let service=peripheral.services?.first(where:{$0.uuid==BLE.service}) else{status="Serviço não encontrado";return}
        peripheral.discoverCharacteristics([BLE.dog01,BLE.dog02,BLE.all,BLE.control],for:service)
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?){
        guard error==nil else{status="Erro ao descobrir dados BLE";return}
        let chars=service.characteristics ?? []
        all=chars.first{$0.uuid==BLE.all};control=chars.first{$0.uuid==BLE.control}
        canConfigure=control?.properties.contains(.write)==true
        positions=chars.filter{$0.uuid==BLE.dog01 || $0.uuid==BLE.dog02}
        poll();timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:3,repeats:true){[weak self] _ in Task { @MainActor in self?.poll() }}
    }
    private func poll(){
        guard let raspberry,connected,!disconnectRequested else{return}
        if busy {
            if Date().timeIntervalSince(startedRead)>12 {manager.cancelPeripheralConnection(raspberry)}
            return
        }
        if let pendingInterval,let control {
            self.pendingInterval=nil
            busy=true;startedRead=Date()
            raspberry.writeValue(Data("\(pendingInterval.0),\(pendingInterval.1)".utf8),for:control,type:.withResponse)
            return
        }
        if let all {
            busy=true;startedRead=Date();assembled=Data();offset=0;pageTotal=nil
            if all.properties.contains(.write){raspberry.writeValue(Data("0".utf8),for:all,type:.withResponse)}
            else{raspberry.readValue(for:all)}
        } else {for c in positions{raspberry.readValue(for:c)}}
    }
    func setInterval(dog:String,seconds:Int){
        guard canConfigure,connected,dogs[dog] != nil,(5...3600).contains(seconds) else{commandFeedback="Comando indisponível nesta ligação";return}
        pendingInterval=(dog,seconds);commandFeedback="Pedido em fila para \(dog): \(seconds) s";poll()
    }
    func peripheral(_ peripheral:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?){
        if disconnectRequested {
            if characteristic.uuid==BLE.control{manager.cancelPeripheralConnection(peripheral)}
            return
        }
        if let error{busy=false;syncingClock=false;commandFeedback=error.localizedDescription;return}
        if characteristic.uuid==BLE.all {peripheral.readValue(for:characteristic)}
        else {busy=false;if syncingClock{syncingClock=false}else{commandFeedback="Recetor recebeu o pedido. A aguardar confirmação da coleira."}}
    }
    func peripheral(_ peripheral:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?){
        guard !disconnectRequested,raspberry?.identifier==peripheral.identifier else{return}
        guard error==nil,let data=characteristic.value else{busy=false;status="Erro de leitura BLE";return}
        do {
            if characteristic.uuid==BLE.control {
                network=try JSONDecoder().decode(NetworkStats.self,from:data)
                if (network?.baseType=="ESP32" || network?.baseType=="DOG01"),!clockSent,!busy {
                    clockSent=true;syncingClock=true;busy=true;startedRead=Date()
                    let stamp=Int(Date().timeIntervalSince1970)
                    peripheral.writeValue(Data("TIME,\(stamp)".utf8),for:characteristic,type:.withResponse)
                }
                return
            }
            var payload=data
            if characteristic.uuid==BLE.all,data.starts(with:Data("J1|".utf8)) {
                let bars=data.indices.filter{data[$0]==124}
                guard bars.count>=3,let receivedOffset=Int(String(decoding:data[(bars[0]+1)..<bars[1]],as:UTF8.self)),
                      let total=Int(String(decoding:data[(bars[1]+1)..<bars[2]],as:UTF8.self)),
                      receivedOffset==offset,total>0,total<=1_000_000,
                      pageTotal==nil || pageTotal==total else{throw NSError(domain:"BLE",code:1)}
                pageTotal=total;assembled.append(data[(bars[2]+1)...]);offset=assembled.count
                guard offset<=total else{throw NSError(domain:"BLE",code:2)}
                if offset<total {peripheral.writeValue(Data(String(offset).utf8),for:characteristic,type:.withResponse);return}
                payload=assembled
            }
            let records: [DogRecord]
            if characteristic.uuid==BLE.all {records=try JSONDecoder().decode(DogsEnvelope.self,from:payload).dogs}
            else {records=[try JSONDecoder().decode(DogRecord.self,from:payload)]}
            let now=Date();var next=dogs
            for dog in records {
                guard dog.id.range(of:"^DOG[0-9]{1,6}$",options:.regularExpression) != nil else{continue}
                next[dog.id]=dog;snapshots[dog.id]=now
                let key="\(dog.session ?? ""):\(dog.seq ?? -1)"
                if lastSample[dog.id] != key, dog.seq != nil {
                    lastSample[dog.id]=key
                    append(HistoryItem(dog:dog.id,at:dog.receivedAt.map{Date(timeIntervalSince1970:Double($0))} ?? now.addingTimeInterval(-(dog.secondsSinceRx ?? 0)),type:"Posição",detail:dog.route?.joined(separator:" → ") ?? "Recebida",lat:dog.lat,lon:dog.lon,battery:dog.batPct,seq:dog.seq,session:dog.session))
                }
            }
            dogs=next;lastRead=now;busy=false;status="Ligado a \(baseName)"
            if let control{peripheral.readValue(for:control)}
        } catch {busy=false;status="Dados BLE incompletos: \(error.localizedDescription)"}
    }
    private func append(_ item:HistoryItem){
        history.append(item);history=Array(history.suffix(3000))
        if let data=try? JSONEncoder().encode(history){try? data.write(to:historyURL,options:.atomic)}
    }
    func inspect(now:Date,batteryLimit:Int,alerts:Bool){
        guard baseAvailable(now) else{return} // Bluetooth perdido nao prova perda da coleira.
        for dog in dogs.values {
            guard dog.seq != nil else{continue}
            let missing=lost(dog,now)
            if let previous=contact[dog.id],previous != missing {
                let title=missing ? "Sem contacto" : "Contacto recuperado"
                append(HistoryItem(dog:dog.id,at:now,type:title,detail:"Estado observado no iPhone",lat:nil,lon:nil,battery:dog.batPct,seq:dog.seq,session:dog.session))
                if alerts{notify("\(dog.id): \(title)")}
            }
            contact[dog.id]=missing
            if let battery=dog.batPct,!missing {
                let low=battery<=batteryLimit
                if low,lowBattery[dog.id] != true,alerts {notify("\(dog.id): bateria \(battery)%")}
                if !low,battery>batteryLimit+5{lowBattery[dog.id]=false}
                if low{lowBattery[dog.id]=true}
            }
        }
    }
    func enableNotifications(){
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]){[weak self] ok,_ in
            Task { @MainActor in self?.notifications=ok;self?.commandFeedback=ok ? "Alertas autorizados" : "Alertas não autorizados" }
        }
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void){
        completionHandler([.banner,.sound])
    }
    private func notify(_ text:String){
        guard notifications else{return};let c=UNMutableNotificationContent();c.title="Coleiras";c.body=text;c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:UUID().uuidString,content:c,trigger:nil))
    }
    func trail(_ dog:String)->[CLLocationCoordinate2D] {
        history.filter{$0.dog==dog && $0.type=="Posição"}.suffix(500).compactMap { item in
            guard let lat=item.lat,let lon=item.lon else{return nil};return CLLocationCoordinate2D(latitude:lat,longitude:lon)
        }
    }
    func export(_ dog:String)->URL? {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(dog)-historico.json")
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        guard let data=try? encoder.encode(history.filter{$0.dog==dog}),(try? data.write(to:url,options:.atomic)) != nil else{return nil}
        return url
    }
}
@MainActor final class PhoneLocation:NSObject,ObservableObject,@preconcurrency CLLocationManagerDelegate {
    @Published var coordinate:CLLocationCoordinate2D?
    @Published var accuracy:Double?
    @Published var updatedAt:Date?
    @Published var denied=false
    private let manager=CLLocationManager()
    override init(){super.init();manager.delegate=self;manager.desiredAccuracy=kCLLocationAccuracyBest}
    func start(){
        switch manager.authorizationStatus {
        case .notDetermined:manager.requestWhenInUseAuthorization()
        case .authorizedAlways,.authorizedWhenInUse:denied=false;manager.startUpdatingLocation()
        case .denied,.restricted:denied=true
        @unknown default:break
        }
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){start()}
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]){
        guard let l=locations.last,l.horizontalAccuracy>=0 else{return}
        coordinate=l.coordinate;accuracy=l.horizontalAccuracy;updatedAt=l.timestamp
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error){accuracy=nil}
}
struct ContentView:View {
    @StateObject private var bluetooth=CollarBluetooth()
    @StateObject private var phoneLocation=PhoneLocation()
    @State private var selected="DOG01"
    @State private var tab="Mapa"
    @State private var clock=Date()
    @State private var following=true
    @State private var cameraFocus:[CLLocationCoordinate2D]=[]
    @State private var cameraToken=0
    @State private var interval=15
    @State private var exportURL:URL?
    @AppStorage("alertas-v6") private var alerts=true
    @AppStorage("bateria-limite-v6") private var batteryLimit=20
    private var dog:DogRecord?{bluetooth.dogs[selected]}
    private var ids:[String]{bluetooth.ids.isEmpty ? ["DOG01","DOG02","DOG03"] : bluetooth.ids}
    private var tabs:[String]{["Mapa","Coleira","Comunicação","Histórico","Diagnóstico","Definições"]}
    private var available:Bool{bluetooth.baseAvailable(clock)}
    private var label:String {
        guard available else{return "Sem dados atuais do recetor"}
        guard let dog,dog.seq != nil else{return "A aguardar dados"}
        if bluetooth.lost(dog,clock){return "Sem contacto"}
        return dog.delivery=="local" ? "Posição do recetor DOG01" : dog.delivery=="retransmitida" ? "Ligada por retransmissão" : "Contacto direto"
    }
    private var selectedFresh:Bool {
        guard available,let dog,!bluetooth.lost(dog,clock),let stamp=bluetooth.snapshots[dog.id] else{return false}
        let age=dog.positionAgeS ?? dog.ageMs.map{Double($0)/1000}
        guard let age else{return dog.receivedAt.map{clock.timeIntervalSince1970-Double($0)<30} ?? false}
        return age+max(0,clock.timeIntervalSince(stamp))<(dog.contactTimeoutS ?? 30)
    }
    private var distance:Double? {
        guard let a=phoneLocation.coordinate,let b=dog?.coordinate,
              let updated=phoneLocation.updatedAt,clock.timeIntervalSince(updated)<60,
              phoneLocation.accuracy != nil else{return nil}
        return CLLocation(latitude:a.latitude,longitude:a.longitude).distance(from:CLLocation(latitude:b.latitude,longitude:b.longitude))
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16){
                    HStack {
                        Image(systemName:"pawprint.fill").font(.title).foregroundStyle(.blue)
                        VStack(alignment:.leading){Text("As minhas coleiras").font(.headline);Text(bluetooth.status).font(.caption).foregroundStyle(.secondary)}
                        Spacer();Circle().fill(available ? Color.green : Color.orange).frame(width:10,height:10)
                    }
                    basePicker
                    Picker("Coleira selecionada",selection:$selected){ForEach(ids,id:\.self){Text($0).tag($0)}}.pickerStyle(.menu)
                    ScrollView(.horizontal,showsIndicators:false){HStack{ForEach(tabs,id:\.self){name in
                        Button(name){tab=name}.buttonStyle(.bordered).tint(tab==name ? .blue : .gray)
                    }}}
                    if tab=="Mapa" {mapPanel}
                    else if tab=="Coleira" {collarPanel}
                    else if tab=="Comunicação" {communicationPanel}
                    else if tab=="Histórico" {historyPanel}
                    else if tab=="Diagnóstico" {diagnosticsPanel}
                    else {settingsPanel}
                    Text("Valores indisponíveis aparecem como —. A distância é em linha reta; o sinal medido pode ser o da última coleira retransmissora.").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.background(Color(uiColor:.systemGroupedBackground)).navigationTitle(selected)
            .onAppear{phoneLocation.start()}
            .onChange(of:selected){_,_ in focus()}
            .onReceive(bluetooth.$dogs){records in
                if records[selected]==nil,let first=records.keys.sorted().first{selected=first}
                if following{focus(records)}
            }
            .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()) {now in
                clock=now;bluetooth.inspect(now:now,batteryLimit:batteryLimit,alerts:alerts)
            }
            .sheet(isPresented:Binding(get:{exportURL != nil},set:{if !$0{exportURL=nil}})){
                if let exportURL {ShareSheet(url:exportURL)}
            }
        }
    }
    private var basePicker:some View {
        VStack(alignment:.leading,spacing:10){
            Text("Recetor Bluetooth").font(.headline)
            if bluetooth.connected {
                Text(bluetooth.baseName)
                Button("Desligar e escolher outra base"){bluetooth.disconnectBase()}.buttonStyle(.bordered)
            } else {
                Button("Procurar recetores"){bluetooth.scanBases()}.buttonStyle(.bordered)
                ForEach(bluetooth.bases){base in
                    Button {bluetooth.chooseBase(base.id)} label:{
                        HStack {VStack(alignment:.leading){Text(base.name);Text(String(base.id.uuidString.prefix(8))).font(.caption)};Spacer();Text("\(base.rssi) dBm")}
                    }.buttonStyle(.bordered)
                }
                if bluetooth.bases.isEmpty{Text("Liga o Raspberry ou a DOG01 e procura novamente.").font(.caption)}
            }
            Text("A ligação Bluetooth ativa o recetor escolhido. A DOG01 volta a ser coleira quando desligas.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private var mapPanel:some View {
        VStack(alignment:.leading,spacing:12){
            AppleCollarMap(dogs:dog.map{[$0]} ?? [],recentIDs:selectedFresh ? [selected] : [],trails:[selected:bluetooth.trail(selected)],selectedDog:selected,
                phoneCoordinate:phoneLocation.coordinate,cameraFocus:cameraFocus,cameraToken:cameraToken)
                .frame(height:420).clipShape(RoundedRectangle(cornerRadius:20))
            HStack{Button(following ? "A seguir" : "Seguir coleira"){following.toggle();focus()};Spacer();Button("Minha posição"){
                if let c=phoneLocation.coordinate{following=false;cameraFocus=[c];cameraToken+=1}else{phoneLocation.start()}
            }}.buttonStyle(.bordered)
            Text(label).font(.headline).foregroundStyle(available && dog.map{!bluetooth.lost($0,clock)}==true ? Color.green : Color.orange)
            row("Distância até ti",distance.map{formatDistance($0)} ?? "—")
            if !selectedFresh {
                Text("Distância à última posição conhecida; não representa a posição atual do cão.").font(.caption).foregroundStyle(.orange)
            }
            row("Bateria",dog?.batPct.map{"\($0)%"} ?? "—")
            row("Última comunicação",dog?.receivedAt.map{date($0)} ?? "—")
            row("Recebida há",dog.map{duration(bluetooth.elapsed($0,clock))} ?? "—")
            if phoneLocation.denied{Text("Permite a localização nas Definições do iPhone para calcular a distância.").font(.caption)}
        }
    }
    private var collarPanel:some View {
        VStack(alignment:.leading,spacing:12){
            title("Dados da coleira")
            row("Latitude",dog?.lat.map{String(format:"%.7f",$0)} ?? "—")
            row("Longitude",dog?.lon.map{String(format:"%.7f",$0)} ?? "—")
            row("Velocidade",dog?.speed.map{String(format:"%.1f km/h",$0)} ?? "—")
            row("Bateria",dog?.batPct.map{"\($0)%"} ?? "—")
            row("Tensão",dog?.batV.map{String(format:"%.3f V",$0)} ?? "—")
            row("Satélites",dog?.sat.map(String.init) ?? "—")
            row("Satélites em uso",dog?.satUso.map(String.init) ?? "—")
            row("IDs satélites",clean(dog?.satIds))
            row("Idade da posição",positionAge)
            row("Precisão do iPhone",phoneLocation.accuracy.map{String(format:"± %.0f m",$0)} ?? "—")
            row("Localização do iPhone",phoneLocation.updatedAt.map{$0.formatted(date:.omitted,time:.standard)} ?? "—")
        }
    }
    private var communicationPanel:some View {
        VStack(alignment:.leading,spacing:12){
            title("Comunicação");row("Estado",label)
            row("Última comunicação",dog?.receivedAt.map{date($0)} ?? "—")
            row("Recebida há",dog.map{duration(bluetooth.elapsed($0,clock))} ?? "—")
            row("Sem contacto desde",lostSince)
            row("Última receção direta",dog?.lastDirectAt.map{date($0)} ?? "—")
            row("Percurso",dog?.route?.joined(separator:" → ") ?? "—")
            row("RSSI último salto",dog?.rssi.map{String(format:"%.1f dBm",$0)} ?? "—")
            row("SNR último salto",dog?.snr.map{String(format:"%.1f dB",$0)} ?? "—")
            row("Intervalo confirmado",dog?.sendIntervalS.map{"\($0) s"} ?? "—")
            row("Intervalo pedido",dog?.requestedIntervalS.map{"\($0) s"} ?? "—")
            row("Configuração",clean(dog?.configStatus))
            row("Coleiras conhecidas",bluetooth.network?.knownCount.map(String.init) ?? "—")
            row("Limite de retransmissores",bluetooth.network?.relayLimit.map(String.init) ?? "—")
            row("Bluetooth perdido desde",bluetooth.baseLostAt.map{$0.formatted()} ?? "—")
            Text("Quando o Bluetooth falha, o estado da coleira fica desconhecido: isso não prova perda de LoRa.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var diagnosticsPanel:some View {
        VStack(alignment:.leading,spacing:12){
            title("Diagnóstico");row("ID",selected);row("SEQ",dog?.seq.map(String.init) ?? "—")
            row("Sessão",clean(dog?.session));row("Estado da base",clean(dog?.status));row("Entrega",clean(dog?.delivery))
            row("Idade no pacote",dog?.ageMs.map{"\($0) ms"} ?? "—")
            row("Idade da posição",positionAge)
            row("Prazo sem contacto",dog?.contactTimeoutS.map{duration($0)} ?? "30 s (estimativa app)")
            if let n=bluetooth.network {
                row("Tipo de recetor",n.baseType ?? "Raspberry")
                if let lat=n.baseLat,let lon=n.baseLon{row("GPS da base",String(format:"%.6f, %.6f",lat,lon))}
                if let sat=n.baseSat{row("Satélites da base",String(sat))}
            }
            row("Última leitura Bluetooth",bluetooth.lastRead.map{$0.formatted()} ?? "—")
            ForEach(Array((dog?.links ?? []).enumerated()),id:\.offset){_,hop in
                row("\(hop.from) → \(hop.to)","RSSI \(hop.rssi.map{String(format:"%.1f",$0)} ?? "—") / SNR \(hop.snr.map{String(format:"%.1f",$0)} ?? "—")")
            }
            Text("Contadores de pacotes inválidos, repetidos e filas estão no painel do Raspberry ou no Monitor Série do ESP32. A app não inventa estes valores.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var historyPanel:some View {
        VStack(alignment:.leading,spacing:12){
            title("Histórico registado no iPhone")
            Button("Exportar JSON desta coleira"){exportURL=bluetooth.export(selected)}.buttonStyle(.bordered)
            Text("Guarda até 3000 entradas no total. Só contém dados observados por esta app; não recupera automaticamente o histórico da base.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(bluetooth.history.filter{$0.dog==selected}.suffix(100).reversed())){item in
                VStack(alignment:.leading,spacing:4){
                    Text(item.type).font(.headline);Text(item.at.formatted()).font(.caption)
                    Text(item.detail).font(.caption)
                    if let lat=item.lat,let lon=item.lon{Text(String(format:"%.6f, %.6f",lat,lon)).font(.caption.monospaced())}
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
            }
        }
    }
    private var settingsPanel:some View {
        VStack(alignment:.leading,spacing:16){
            title("Definições de \(selected)")
            Picker("Intervalo de envio",selection:$interval){ForEach([5,15,30,60,120,300],id:\.self){Text("\($0) segundos").tag($0)}}
            Button("Aplicar intervalo"){bluetooth.setInterval(dog:selected,seconds:interval)}.buttonStyle(.borderedProminent).disabled(!available || !bluetooth.canConfigure || dog==nil)
            Text(bluetooth.commandFeedback).font(.caption)
            row("Confirmação da coleira",clean(dog?.configStatus))
            Text("O rádio pode adiar o envio. A escrita Bluetooth confirma apenas o pedido ao recetor.").font(.caption).foregroundStyle(.secondary)
            Toggle("Alertas de contacto e bateria",isOn:$alerts)
            Stepper("Bateria baixa: \(batteryLimit)%",value:$batteryLimit,in:5...50,step:5)
            Button("Autorizar notificações"){bluetooth.enableNotifications()}.buttonStyle(.bordered)
            Text("Os alertas são avaliados enquanto a app recebe dados em primeiro plano. Não há garantia de vigilância com a app fechada.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var positionAge:String {
        guard let dog,let stamp=bluetooth.snapshots[dog.id] else{return "—"}
        let age=dog.positionAgeS ?? dog.ageMs.map{Double($0)/1000}
        return age.map{duration($0+max(0,clock.timeIntervalSince(stamp)))} ?? "—"
    }
    private var lostSince:String {
        guard available else{return "Desconhecido: sem Bluetooth atual"}
        guard let dog,bluetooth.lost(dog,clock) else{return "—"}
        if let at=dog.contactLostAt{return date(at)}
        guard let received=dog.receivedAt else{return "—"}
        return date(received+Int(dog.contactTimeoutS ?? 30))+" (estimado)"
    }
    private func focus(_ records:[String:DogRecord]?=nil){
        guard following,let c=(records ?? bluetooth.dogs)[selected]?.coordinate else{return}
        cameraFocus=[c];cameraToken+=1
    }
    private func row(_ name:String,_ value:String)->some View {
        HStack(alignment:.top){Text(name).foregroundStyle(.secondary);Spacer(minLength:15);Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)}
            .font(.subheadline).padding(12).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:12))
    }
    private func title(_ s:String)->some View{Text(s).font(.title3.bold())}
    private func clean(_ s:String?)->String{guard let s,!s.isEmpty,s != "NA" else{return "—"};return s}
    private func date(_ t:Int)->String{Date(timeIntervalSince1970:Double(t)).formatted(date:.abbreviated,time:.standard)}
    private func duration(_ s:Double)->String{if s>1e8{return "—"};let n=max(0,Int(s));return n<60 ? "\(n) s" : n<3600 ? "\(n/60) min \(n%60) s" : "\(n/3600) h \((n%3600)/60) min"}
    private func formatDistance(_ d:Double)->String{d>=1000 ? String(format:"%.2f km",d/1000) : String(format:"%.0f m",d)}
}
private struct ShareSheet:UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController{UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ c:UIActivityViewController,context:Context){}
}
private struct AppleCollarMap: UIViewRepresentable {
    let dogs: [DogRecord]
    let recentIDs: Set<String>
    let trails: [String: [CLLocationCoordinate2D]]
    let selectedDog: String?
    let phoneCoordinate: CLLocationCoordinate2D?
    let cameraFocus: [CLLocationCoordinate2D]
    let cameraToken: Int

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastCameraToken = -1
        var recentDogs: Set<String> = []

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let item = annotation as? MKPointAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "dog") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: item, reuseIdentifier: "dog")
            view.annotation = item
            view.canShowCallout = true
            let id = item.title ?? ""
            view.markerTintColor = id == "Minha posição" ? .systemTeal
                : (!recentDogs.contains(id) ? .systemGray
                   : (id == "DOG01" ? .systemBlue : .systemOrange))
            view.glyphImage = UIImage(systemName: id == "Minha posição" ? "location.fill" : "pawprint.fill")
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = line.title == "DOG01" ? .systemBlue : .systemOrange
            renderer.lineWidth = 3
            return renderer
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.5, longitude: -8),
                                         span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.recentDogs = recentIDs
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)
        for dog in dogs {
            guard let position = dog.coordinate else { continue }
            let marker = MKPointAnnotation()
            marker.coordinate = position
            marker.title = dog.id
            marker.subtitle = recentIDs.contains(dog.id) ? "Posição recente" : "Última posição conhecida"
            map.addAnnotation(marker)
        }
        if let phoneCoordinate {
            let marker = MKPointAnnotation()
            marker.coordinate = phoneCoordinate
            marker.title = "Minha posição"
            map.addAnnotation(marker)
        }
        if let selectedDog, let coordinates = trails[selectedDog], coordinates.count > 1 {
            var points = coordinates
            let line = MKPolyline(coordinates: &points, count: points.count)
            line.title = selectedDog
            map.addOverlay(line)
        }
        if cameraToken != coordinator.lastCameraToken {
            coordinator.lastCameraToken = cameraToken
            if cameraFocus.count == 1, let point = cameraFocus.first {
                map.setRegion(MKCoordinateRegion(center: point,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)), animated: true)
            } else if !cameraFocus.isEmpty {
                let markers = map.annotations.filter { item in
                    cameraFocus.contains { point in
                        abs(point.latitude - item.coordinate.latitude) < 0.0000001 &&
                        abs(point.longitude - item.coordinate.longitude) < 0.0000001
                    }
                }
                var bounds = MKMapRect.null
                for marker in markers {
                    let point = MKMapPoint(marker.coordinate)
                    bounds = bounds.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
                }
                if !bounds.isNull {
                    map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 80, left: 50, bottom: 180, right: 50), animated: true)
                }
            }
        }
    }
}

@main struct ColeirasCaesApp:App {var body:some Scene{WindowGroup{ContentView()}}}
